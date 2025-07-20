---

````markdown
# 🛠️ PostgreSQL HA Cluster (Patroni + etcd + HAProxy + Keepalived) Setup Guide

## 📌 Overview

This guide walks you through setting up a secure, 3‑node PostgreSQL HA cluster using Patroni and etcd, with HAProxy/Keepalived for load balancing and VIP failover. It includes TLS for inter-component communication, monitoring with Prometheus/Grafana, and validation steps.

---

## ✅ Prerequisites

1. Three Ubuntu VMs (e.g., node1, node2, node3)
2. Static IPs:
   - node1: `10.0.0.1`
   - node2: `10.0.0.2`
   - node3: `10.0.0.3`
   - Floating VIP: `10.0.0.100`
3. Script: `setup_pg_cluster.sh` (provided separately)

---

## 🗝️ Step 1: Create and Distribute CA

Run once on an admin machine:

```bash
openssl req -x509 -nodes -days 3650 \
  -newkey rsa:4096 -keyout ca.key -out ca.crt \
  -subj "/CN=MyCluster-CA"
````

Copy `ca.key` and `ca.crt` to each node in `/etc/ssl/ca/` (via `scp`, etc.). These are **shared CA files** used for all nodes.

---

## 🖥️ Step 2: Run the Setup Script on Each Node

On each VM (`node1`, `node2`, `node3`):

```bash
sudo mv ca.key ca.crt /etc/ssl/ca/
sudo chmod 600 /etc/ssl/ca/ca.key

sudo ./setup_pg_cluster.sh <NODE_NAME> <NODE_IP> <VIP>

# Example for node1:
sudo ./setup_pg_cluster.sh node1 10.0.0.1 10.0.0.100
```

This installs and configures:

* PostgreSQL 16 + Patroni (with TLS on REST)
* etcd cluster (client/peer TLS)
* HAProxy & Keepalived (VIP failover)
* Chrony for time-sync
* Prometheus exporters (node + PostgreSQL)
* Hardened `pg_hba.conf`

---

## 📋 Validation Steps

### 1. System services

```bash
systemctl status patroni etcd haproxy keepalived
```

### 2. etcd health

```bash
ss -ltn | grep 2379
etcdctl --cacert /etc/ssl/ca/ca.crt member list
```

### 3. Patroni cluster

```bash
patronictl -c /data/pg/patroni.yml list
```

Expect 1 master, 2 replicas.

### 4. VIP assignment

```bash
ip addr | grep 10.0.0.100
```

VIP should be present on the current HAProxy master.

---

## 🔄 Failover Testing

### A. PostgreSQL automatic failover

```bash
sudo systemctl stop patroni
```

* Confirm replica becomes master via `patronictl list`.
* The VIP remains active – HAProxy stays bound.

### B. HAProxy/VIP failover

On current VIP holder:

```bash
sudo systemctl stop haproxy
```

* VIP should move to the next node (check with `ip addr | grep`).

---

## 🔐 TLS Verification

On each node:

```bash
curl --cacert /etc/ssl/ca/ca.crt https://127.0.0.1:2379/metrics
curl --cacert /etc/ssl/ca/ca.crt https://127.0.0.1:8008/cluster
```

Expect JSON responses with no certificate errors.

---

## 🧪 Client Connection Tests

### A. Primary (read/write):

```bash
psql -h 10.0.0.100 -p 5432 -U postgres -d yourdb
SELECT pg_is_in_recovery();  -- should return "false"
```

### B. Replica (read-only):

```bash
psql -h 10.0.0.100 -p 5433 -U postgres -d yourdb
SELECT pg_is_in_recovery();  -- should return "true"
```

---

## 📈 Monitoring with Prometheus + Grafana

1. Deploy Prometheus + Grafana on a **separate VM**.
2. Add the following scrape config in `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'postgres_exporter'
    static_configs:
      - targets: ['node1:9187', 'node2:9187', 'node3:9187']
  - job_name: 'patroni'
    metrics_path: /metrics
    static_configs:
      - targets: ['node1:8008', 'node2:8008', 'node3:8008']
  - job_name: 'etcd'
    static_configs:
      - targets: ['node1:2379', 'node2:2379', 'node3:2379']
```

3. Import Patroni dashboard **ID 18870** from Grafana.
4. Validate exporters:

```bash
curl localhost:9187/metrics
curl localhost:8008/metrics
curl localhost:2379/metrics
```

---

## ⚙️ Final Checks

| Component                 | Test Command                                 |
| ------------------------- | -------------------------------------------- |
| Time sync                 | `chronyc tracking`                           |
| HAProxy/IP non-local bind | `sysctl net.ipv4.ip_nonlocal_bind`           |
| `pg_hba.conf` security    | Attempt connection from outside VIP subnet   |
| Failover resilience       | Stop Patroni or HAProxy and observe recovery |

---

## 🧾 Summary

By following these steps, you will have a **secure, monitored, and highly available PostgreSQL cluster** with:

* Mutual TLS encryption across etcd, Patroni, REST API
* Automatic master failover and floating VIP
* Monitoring via Prometheus + Grafana
* Hardened authentication settings

