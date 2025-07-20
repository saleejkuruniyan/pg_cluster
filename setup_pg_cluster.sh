#!/usr/bin/env bash
# Usage: sudo ./setup_pg_cluster.sh NODE_NAME NODE_IP VIP
NODE_NAME="$1"; NODE_IP="$2"; VIP="$3"
PEERS=("node1:10.0.0.1" "node2:10.0.0.2" "node3:10.0.0.3")
set -e

# 1. Install necessary packages
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  postgresql-16 postgresql-contrib-16 etcd patroni \
  haproxy keepalived prometheus-node-exporter curl wget \
  chrony openssl

# 2. Hostname and /etc/hosts
hostnamectl set-hostname "$NODE_NAME"
echo "$NODE_IP $NODE_NAME" | tee -a /etc/hosts
for PEER in "${PEERS[@]}"; do
  ip=${PEER#*:}; name=${PEER%:*}
  echo "$ip $name" >> /etc/hosts
done

# 3. Disk setup
if lsblk /dev/sdb &>/dev/null; then
  mkfs.xfs -f /dev/sdb
  mkdir -p /data
  mount /dev/sdb /data
  echo "/dev/sdb /data xfs defaults 0 0" >> /etc/fstab
fi

# 4. Time sync with Chrony
systemctl enable --now chrony

# 5. Generate TLS certificates for etcd & Patroni
SSL_DIR=/etc/ssl/$NODE_NAME
mkdir -p "$SSL_DIR"

# Node cert
openssl req -newkey rsa:4096 -nodes \
  -keyout $SSL_DIR/node.key -out $SSL_DIR/node.csr \
  -subj "/CN=$NODE_NAME"
openssl x509 -req -in $SSL_DIR/node.csr -CA /etc/ssl/ca/ca.crt \
  -CAkey /etc/ssl/ca/ca.key -CAcreateserial \
  -days 3650 -out $SSL_DIR/node.crt

# 6. Configure etcd with TLS
cat > /etc/default/etcd <<EOF
ETCD_NAME="$NODE_NAME"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_CLUSTER="${PEERS[*]/%/:2380}"
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_LISTEN_PEER_URLS="https://${NODE_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="https://${NODE_IP}:2379"
ETCD_ADVERTISE_CLIENT_URLS="https://${NODE_IP}:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://${NODE_IP}:2380"
ETCD_CERT_FILE="$SSL_DIR/node.crt"
ETCD_KEY_FILE="$SSL_DIR/node.key"
ETCD_TRUSTED_CA_FILE="$SSL_DIR/ca.crt"
ETCD_CLIENT_CERT_AUTH="true"
ETCD_PEER_CERT_FILE="$SSL_DIR/node.crt"
ETCD_PEER_KEY_FILE="$SSL_DIR/node.key"
ETCD_PEER_TRUSTED_CA_FILE="$SSL_DIR/ca.crt"
ETCD_PEER_CLIENT_CERT_AUTH="true"
EOF
systemctl daemon-reload
systemctl enable --now etcd

# 7. Patroni setup with TLS on REST API
mkdir -p /data/pg/{data,logs,patroni}
chown -R postgres:postgres /data/pg

cat > /data/pg/patroni.yml <<EOF
scope: postgres-cluster
namespace: /service/
name: $NODE_NAME

etcd3:
  hosts: ${PEERS[*]/%/:2379}
  protocol: https

restapi:
  listen: 0.0.0.0:8008
  connect_address: $NODE_IP:8008
  certfile: $SSL_DIR/node.crt
  keyfile: $SSL_DIR/node.key
  cafile: $SSL_DIR/ca.crt
  verify_client: required

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_segments: 8
  initdb:
    - encoding: UTF8
    - data-checksums
  users:
    replicator:
      password: rep-pass
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $NODE_IP:5432
  data_dir: /data/pg/data
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    replication:
      username: replicator
      password: rep-pass
    superuser:
      username: postgres
      password: pg-pass
  parameters:
    unix_socket_directories: '.'

tags:
  nofailover: false
  noloadbalance: false

ctl:
  certfile: $SSL_DIR/node.crt
  keyfile: $SSL_DIR/node.key
  cacert: $SSL_DIR/ca.crt
  insecure: false
EOF

cat > /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni Service
After=network.target
[Service]
User=postgres
ExecStart=/usr/bin/patroni /data/pg/patroni.yml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now patroni

# 8. HAProxy + Keepalived
cat > /etc/haproxy/haproxy.cfg <<EOF
frontend pg_rw
  bind *:5432
  mode tcp
  default_backend pg_rw

backend pg_rw
  mode tcp
  option httpchk GET /primary
$(for PEER in "${PEERS[@]}"; do echo "  server ${PEER%:*} ${PEER#*:}:5432 check port 8008"; done)

frontend pg_ro
  bind *:5433
  mode tcp
  default_backend pg_ro

backend pg_ro
  mode tcp
  option httpchk GET /replica
  balance roundrobin
$(for PEER in "${PEERS[@]}"; do echo "  server ${PEER%:*} ${PEER#*:}:5432 check port 8008"; done)

listen stats
  bind *:9600
  stats enable
  stats uri /stats
  stats auth admin:StrongPass
EOF

cat > /etc/keepalived/check_haproxy.sh <<'EOF'
#!/bin/bash
ss -ltn | grep -q ':5432' || exit 1
EOF
chmod +x /etc/keepalived/check_haproxy.sh

INTERFACE=$(ip route | awk '/default/ {print $5;exit}')
PRIORITY=90
[[ $NODE_NAME == node1 ]] && PRIORITY=100

cat > /etc/keepalived/keepalived.conf <<EOF
global_defs { enable_script_security; script_user root; }
vrrp_script chk { script "/etc/keepalived/check_haproxy.sh"; interval 2; fall 2; rise 1; }
vrrp_instance VI_1 {
  state BACKUP
  interface $INTERFACE
  virtual_router_id 50
  priority $PRIORITY
  advert_int 1
  virtual_ipaddress { $VIP }
  track_script { chk }
}
EOF

systemctl enable --now haproxy keepalived

# 9. Exporters for Monitoring
wget -q https://github.com/prometheus-community/postgres_exporter/releases/download/v0.11.1/postgres_exporter_v0.11.1_linux-amd64.tar.gz
tar xzf postgres_exporter*.tar.gz -C /usr/local/bin

cat > /etc/systemd/system/postgres_exporter.service <<EOF
[Unit]
Description=Prometheus PostgreSQL Exporter
After=network.target
[Service]
User=postgres
Environment="DATA_SOURCE_NAME=postgresql://postgres:pg-pass@localhost:5432/?sslmode=disable"
ExecStart=/usr/local/bin/postgres_exporter
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now postgres_exporter

# 10. Harden pg_hba.conf
cat > /data/pg/data/pg_hba.conf <<EOF
local   all             all                                     peer
host    replication     replicator    ${VIP}/24        scram-sha-256
host    all             all           ${VIP}/24        md5
EOF
systemctl reload postgresql

# 11. Sysctl tuning for HAProxy VIP
cat > /etc/sysctl.d/99-haproxy.conf <<EOF
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl --system

echo "✅ Setup complete on $NODE_NAME"

