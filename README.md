# ELK Stack on RHEL 9 — Bare Metal Installation Guide

Production-ready installation of Elasticsearch 8.x, Logstash 8.x, Kibana 8.x, and Filebeat 8.x directly on physical (bare metal) servers running Red Hat Enterprise Linux 9.

> **Scope:** This guide covers RPM package installation on dedicated hardware only.
> Docker, Kubernetes, and virtual machine deployments are out of scope.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Hardware Requirements](#hardware-requirements)
3. [BIOS / Firmware Recommendations](#bios--firmware-recommendations)
4. [Storage Layout](#storage-layout)
5. [Network Configuration](#network-configuration)
6. [OS Pre-installation Checklist](#os-pre-installation-checklist)
7. [Directory Structure](#directory-structure)
8. [Installation](#installation)
9. [Configuration Reference](#configuration-reference)
10. [Bare Metal OS Tuning](#bare-metal-os-tuning)
11. [Multi-Node Cluster](#multi-node-cluster)
12. [Security Notes](#security-notes)
13. [Troubleshooting](#troubleshooting)

---

## Architecture

```
Physical Host A                      Physical Host B (optional, for Filebeat agents)
┌─────────────────────────┐          ┌──────────────────────┐
│  [Elasticsearch :9200]  │◄─────────│  [Filebeat]          │
│  [Logstash      :5044]  │          │  /var/log/messages   │
│  [Kibana        :5601]  │          │  /var/log/secure      │
│  [Filebeat]             │          │  /var/log/app/*.log   │
└─────────────────────────┘          └──────────────────────┘

Data flow:
  Filebeat (each host)
      │  TLS / Beats protocol :5044
      ▼
  Logstash  ── grok / geoip / filter ──►  Elasticsearch :9200
                                                │
                                           Kibana :5601
                                        (dashboards & alerts)
```

All components run as **systemd services** managed by the OS init system — no container runtime is involved.

---

## Hardware Requirements

### ELK Server (Elasticsearch + Logstash + Kibana on one host)

| Component | Minimum | Recommended |
|---|---|---|
| CPU | 8 physical cores | 16+ physical cores (Intel Xeon / AMD EPYC) |
| RAM | 32 GB | 64 GB+ |
| OS Disk | 60 GB SSD | 120 GB SSD (RAID 1) |
| Data Disk | 500 GB SSD | 2+ TB NVMe SSD (RAID 10 or JBOD) |
| NIC | 1 Gbps | 10 Gbps (bonded pair) |

> **RAM rule:** Set Elasticsearch JVM heap to **half of physical RAM**, maximum **31 GB**.
> The other half is used by the OS page cache for Lucene segment files.

### Filebeat Agent Nodes (log shippers)

| Component | Minimum |
|---|---|
| CPU | 2 physical cores |
| RAM | 2 GB |
| Disk | OS disk only (Filebeat writes no persistent data) |
| NIC | 1 Gbps |

### Tested Hardware

The configuration in this repository has been validated on:

- Dell PowerEdge R740 / R750 (Intel Xeon Scalable)
- HPE ProLiant DL380 Gen10 / Gen11
- Supermicro SuperServer 1029P series

---

## BIOS / Firmware Recommendations

Configure these settings in the server's BIOS/UEFI **before** installing the OS.
These settings directly affect Elasticsearch latency and throughput.

| Setting | Recommended Value | Reason |
|---|---|---|
| CPU Power Management | **Maximum Performance** (not OS-controlled) | Prevents frequency scaling delays |
| C-States | **Disabled** (or C1 only) | Eliminates wake-up latency on CPU idle |
| Hyper-Threading | Enabled | More logical CPUs benefit Logstash worker threads |
| NUMA | **Enabled** | Allows OS to pin Elasticsearch to local memory |
| Memory Mode | **Flat / DRAM** (not AppDirect) | Full DRAM speed for JVM heap |
| Turbo Boost | Enabled | Higher single-thread performance for Lucene searches |
| I/O Virtualization (VT-d / SR-IOV) | Optional | Only needed if using DPDK NIC |
| Secure Boot | Enabled | Required for RHEL 9 kernel module signing |

> On Dell servers set **System Profile → Performance** in iDRAC.
> On HPE servers set **Power Regulator → HP Static High Performance Mode** in iLO.

---

## Storage Layout

Elasticsearch performance is heavily I/O bound. Use dedicated disks for data.

### Recommended Partition Scheme

```
/dev/sda  (OS disk — RAID 1 recommended)
├── /boot/efi       1 GB     EFI System Partition
├── /boot           1 GB     Boot
├── swap            RAM size  (or disable swap entirely, see tuning)
└── /               remaining  OS root (xfs)

/dev/sdb  (or NVMe /dev/nvme0n1 — data disk, RAID 10 if multiple drives)
└── /var/lib/elasticsearch   100% of disk  (xfs, mounted with noatime)

/dev/sdc  (optional — separate log disk)
└── /var/log                 100% of disk  (xfs)
```

### Mount Options

Add `noatime` to the Elasticsearch data mount in `/etc/fstab` to reduce unnecessary inode updates:

```
/dev/sdb1  /var/lib/elasticsearch  xfs  defaults,noatime,nodiratime  0 2
```

### RAID Recommendations

| RAID Level | Use Case |
|---|---|
| RAID 1 | OS disk — redundancy without performance overhead |
| RAID 10 | Data disk — best balance of redundancy and write throughput |
| RAID 5/6 | **Avoid** — write penalty degrades Elasticsearch indexing |

---

## Network Configuration

### NIC Bonding (recommended for production)

Create an active-backup or LACP bond for redundancy and throughput:

```bash
# Install NetworkManager bond support
dnf install -y NetworkManager

# Create bond interface
nmcli con add type bond ifname bond0 bond.options "mode=active-backup,miimon=100"
nmcli con add type ethernet ifname eth0 master bond0
nmcli con add type ethernet ifname eth1 master bond0

# Assign static IP to bond
nmcli con mod bond-bond0 ipv4.addresses "192.168.10.10/24" \
  ipv4.gateway "192.168.10.1" \
  ipv4.dns "192.168.10.1" \
  ipv4.method manual
nmcli con up bond-bond0
```

### Network Firewall Ports

| Port | Protocol | Direction | Service |
|---|---|---|---|
| 9200 | TCP | inbound | Elasticsearch HTTP (REST API) |
| 9300 | TCP | inbound | Elasticsearch transport (node-to-node) |
| 5601 | TCP | inbound | Kibana web UI |
| 5044 | TCP | inbound | Logstash Beats input (Filebeat → Logstash) |
| 9600 | TCP | localhost only | Logstash monitoring API |

Open only ports required for your deployment. Restrict `9200` and `9300` to the ELK subnet — never expose them to the public internet.

---

## OS Pre-installation Checklist

Complete these steps on a **RHEL 9 minimal install** before running the scripts.

```bash
# 1. Register with Red Hat Subscription Manager
subscription-manager register --username <rhsm-user> --auto-attach

# 2. Enable required repositories
subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms
subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms

# 3. Apply all OS updates
dnf update -y && reboot

# 4. Verify SELinux is enforcing (required)
getenforce    # must return "Enforcing"

# 5. Set a static hostname
hostnamectl set-hostname elk-node-01.example.com

# 6. Verify the data disk is mounted
df -h /var/lib/elasticsearch   # must show the dedicated data disk

# 7. Confirm system time is synchronized (critical for cluster operations)
timedatectl status             # NTP synchronized: yes
timedatectl set-timezone UTC
```

---

## Directory Structure

```
ELK-setup/
├── elasticsearch/
│   ├── elasticsearch.yml              # Main Elasticsearch config
│   └── jvm.options.d/
│       └── heap.options               # JVM heap — set to ½ physical RAM
├── logstash/
│   ├── logstash.yml                   # Main Logstash config
│   └── conf.d/
│       ├── 01-beats-input.conf        # mTLS Beats listener :5044
│       ├── 10-syslog-filter.conf      # Grok / geoip filters
│       └── 99-elasticsearch-output.conf  # ES output with ILM routing
├── kibana/
│   └── kibana.yml                     # Main Kibana config
├── filebeat/
│   └── filebeat.yml                   # Log shipper (bare metal, no cloud/container metadata)
└── scripts/
    ├── 01-install-elk.sh              # Install RPMs + bare metal OS tuning
    ├── 02-generate-certs.sh           # TLS certs via elasticsearch-certutil
    ├── 03-configure-security.sh       # Passwords + keystores
    ├── 04-start-services.sh           # Firewall, SELinux, systemd enable/start
    ├── 05-ilm-policy.sh               # ILM retention policy + index template
    └── 06-health-check.sh             # Cluster, node, service health report
```

---

## Installation

Clone this repository onto each ELK server, then run each script **as root** in order.

```bash
# Clone the repo
git clone https://github.com/rajasekar21/ELK-setup.git
cd ELK-setup

# Make scripts executable
chmod +x scripts/*.sh

# Step 1 — Install packages and apply bare metal OS tuning
sudo bash scripts/01-install-elk.sh

# Step 2 — Generate TLS certificates for all components
sudo bash scripts/02-generate-certs.sh

# Step 3 — Set built-in user passwords and configure keystores
sudo bash scripts/03-configure-security.sh

# Step 4 — Open firewall ports, apply SELinux labels, start services
sudo bash scripts/04-start-services.sh

# Step 5 — Apply ILM retention policy and index template
sudo bash scripts/05-ilm-policy.sh

# Step 6 — Verify everything is healthy
sudo bash scripts/06-health-check.sh
```

> Each script must complete successfully before running the next.
> If any script fails, check `journalctl -xe` and re-run after fixing the issue.

---

## Configuration Reference

### Elasticsearch (`elasticsearch/elasticsearch.yml`)

| Key | Default | Notes |
|---|---|---|
| `cluster.name` | `elk-cluster` | Must match across all nodes in a cluster |
| `node.name` | `node-1` | Set to the physical hostname |
| `network.host` | `0.0.0.0` | Bind to all interfaces; restrict with firewall |
| `http.port` | `9200` | REST API |
| `transport.port` | `9300` | Inter-node communication |
| `discovery.type` | `single-node` | Change to seed-based for multi-node |
| `bootstrap.memory_lock` | `true` | **Required on bare metal** — prevents heap swapping |
| `xpack.security.enabled` | `true` | TLS + authentication enforced |

### JVM Heap (`elasticsearch/jvm.options.d/heap.options`)

Allocate **exactly half** of physical RAM, capped at **31 GB**.
Equal `-Xms` and `-Xmx` values eliminate heap resizing at runtime.

| Physical RAM | Heap Setting |
|---|---|
| 32 GB | `-Xms16g -Xmx16g` |
| 64 GB | `-Xms31g -Xmx31g` (cap at 31 g) |
| 128 GB | `-Xms31g -Xmx31g` (cap at 31 g) |

Edit `elasticsearch/jvm.options.d/heap.options` before running `01-install-elk.sh`.

### Logstash Pipeline (`logstash/conf.d/`)

| File | Purpose |
|---|---|
| `01-beats-input.conf` | Accepts Filebeat events over mTLS on port 5044 |
| `10-syslog-filter.conf` | Grok parsing for syslog and nginx; GeoIP enrichment |
| `99-elasticsearch-output.conf` | ILM-aware output; parse-failure routing to a separate index |

Logstash `pipeline.workers` in `logstash.yml` is set to `2`. On a bare metal server with many cores, increase this to `(number of physical cores / 2)`:

```yaml
pipeline.workers: 8   # for a 16-core server
```

### Kibana (`kibana/kibana.yml`)

| Key | Default | Notes |
|---|---|---|
| `server.host` | `0.0.0.0` | Restrict with firewall; put behind nginx in production |
| `server.ssl.enabled` | `true` | TLS enabled on port 5601 |
| `xpack.security.session.idleTimeout` | `1h` | Adjust per security policy |

### Filebeat (`filebeat/filebeat.yml`)

Cloud and container metadata processors (`add_cloud_metadata`, `add_docker_metadata`, `add_kubernetes_metadata`) are **not present** — this config is for bare metal hosts only.

Default log paths collected:

| Log Source | Path |
|---|---|
| System syslog | `/var/log/messages` |
| Authentication | `/var/log/secure` |
| Audit | `/var/log/audit/audit.log` |
| Nginx access/error | `/var/log/nginx/{access,error}.log` |
| Application | `/var/log/app/*.log` |

### ILM Retention (`scripts/05-ilm-policy.sh`)

| Phase | Trigger | Action |
|---|---|---|
| Hot | immediately | Rollover at 50 GB or 1 day |
| Warm | after 3 days | Shrink to 1 shard, forcemerge |
| Cold | after 30 days | Freeze index |
| Delete | after 90 days | Delete index |

---

## Bare Metal OS Tuning

`scripts/01-install-elk.sh` applies the following tuning automatically. This section documents what is done and why.

### tuned Profile

```bash
tuned-adm profile throughput-performance
```

Selects the `throughput-performance` profile which sets CPU governor to `performance`, disables power-saving C-states from the OS side, and tunes kernel I/O parameters for maximum throughput.

### Transparent Huge Pages (THP) — Disabled

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

THP causes unpredictable latency spikes in the JVM garbage collector and Elasticsearch's memory allocator. It is disabled via a systemd oneshot service that runs before Elasticsearch starts, and persists across reboots.

### CPU Frequency Governor

```bash
echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

Forces the CPU to run at maximum frequency, eliminating frequency-scaling delays that add latency to Lucene search operations. Requires the BIOS CPU power setting to allow OS control; if not, set it directly in BIOS.

### Kernel Parameters (`/etc/sysctl.d/99-elk-baremetal.conf`)

| Parameter | Value | Reason |
|---|---|---|
| `vm.max_map_count` | `262144` | Elasticsearch minimum requirement |
| `vm.swappiness` | `1` | Near-zero swapping; heap must stay in RAM |
| `vm.overcommit_memory` | `1` | Prevents OOM kills during large allocations |
| `net.core.rmem_max / wmem_max` | `134217728` | 128 MB socket buffers for high-volume log ingestion |
| `net.ipv4.tcp_congestion_control` | `bbr` | Better throughput on 10 GbE links |
| `fs.file-max` | `2097152` | Supports Elasticsearch's many open file handles |

### I/O Scheduler

| Disk Type | Scheduler | Reason |
|---|---|---|
| NVMe / SSD | `none` | No reordering needed; device has its own queue |
| HDD | `mq-deadline` | Minimises seek time; avoids starvation |

The script detects the disk type for `/var/lib/elasticsearch` automatically and sets the correct scheduler. The setting is persisted via a udev rule.

### File Descriptor and Thread Limits (`/etc/security/limits.d/99-elasticsearch.conf`)

| User | Limit | Value |
|---|---|---|
| elasticsearch | nofile (open files) | 1,048,576 |
| elasticsearch | nproc (threads) | 65,535 |
| elasticsearch | memlock | unlimited |
| logstash | nofile | 131,072 |
| logstash | nproc | 16,384 |

### Memory Lock (systemd override)

```ini
[Service]
LimitMEMLOCK=infinity
```

Required for `bootstrap.memory_lock: true` in `elasticsearch.yml`. Prevents the JVM heap from being paged to disk under memory pressure — critical for consistent query latency on bare metal.

---

## Multi-Node Cluster

To run a 3-node cluster across three physical servers:

**On each node**, set a unique `node.name` and the IP of all seed hosts in `elasticsearch.yml`:

```yaml
# Comment out single-node mode
# discovery.type: single-node

discovery.seed_hosts:
  - "192.168.10.10"   # node-1 (this server)
  - "192.168.10.11"   # node-2
  - "192.168.10.12"   # node-3

cluster.initial_master_nodes:
  - "node-1"
  - "node-2"
  - "node-3"
```

**Certificate regeneration:** Re-run `02-generate-certs.sh` with all node hostnames and IPs. The `elasticsearch-certutil` call must include a `--dns` and `--ip` entry for every node. Distribute the shared CA cert to all nodes.

**Shard allocation:** With 3 nodes, set `index.number_of_replicas: 1` so each shard has one replica on a different physical server.

---

## Security Notes

- All inter-component communication uses TLS (Elasticsearch ↔ Logstash ↔ Kibana ↔ Filebeat).
- Passwords are stored in component keystores — never in YAML config files.
- The `.gitignore` excludes `*.p12`, `*.key`, and `*.pem` — **do not commit certificates or passwords**.
- Restrict port `9200` at the firewall so only Logstash and Kibana hosts can reach it.
- Run Kibana behind an nginx or HAProxy reverse proxy with a valid CA-signed certificate in production.
- SELinux remains in **enforcing** mode; `04-start-services.sh` adds the required port type labels.
- Rotate built-in user passwords every 90 days using `elasticsearch-reset-password`.

---

## Troubleshooting

### Service logs

```bash
journalctl -u elasticsearch -f
journalctl -u logstash      -f
journalctl -u kibana        -f
journalctl -u filebeat      -f
```

### Verify bare metal tuning is applied

```bash
# THP
cat /sys/kernel/mm/transparent_hugepage/enabled   # must show: [never]

# CPU governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # must show: performance

# vm.max_map_count
sysctl vm.max_map_count   # must show: 262144

# tuned profile
tuned-adm active          # must show: throughput-performance

# Memory lock (check ES is holding it)
grep -i memlock /proc/$(pgrep -f elasticsearch)/limits
```

### Config validation

```bash
# Logstash pipeline syntax check
/usr/share/logstash/bin/logstash --config.test_and_exit -f /etc/logstash/conf.d/

# Filebeat config and connectivity
filebeat test config  -c /etc/filebeat/filebeat.yml
filebeat test output  -c /etc/filebeat/filebeat.yml
```

### Elasticsearch API checks

```bash
# Cluster health
curl -sk -u elastic https://localhost:9200/_cluster/health?pretty

# Node info (confirm memory_lock is true)
curl -sk -u elastic https://localhost:9200/_nodes?filter_path=nodes.*.process.mlockall

# Shard allocation status
curl -sk -u elastic https://localhost:9200/_cat/shards?v

# Hot threads (diagnosis for high CPU)
curl -sk -u elastic https://localhost:9200/_nodes/hot_threads
```

### Common bare metal issues

| Symptom | Likely Cause | Fix |
|---|---|---|
| Elasticsearch exits with `mlockall failed` | systemd `LimitMEMLOCK` not applied | Run `systemctl daemon-reload`, restart elasticsearch |
| High GC pause times | THP still enabled | Check `cat /sys/kernel/mm/transparent_hugepage/enabled` |
| Slow indexing | I/O scheduler not set | Verify `cat /sys/block/<dev>/queue/scheduler` shows `[none]` or `[mq-deadline]` |
| Network drops under load | Socket buffers too small | Verify `sysctl net.core.rmem_max` returns `134217728` |
| `max file descriptors too low` | limits.conf not loaded | Log out and back in, or reboot; check `ulimit -n` as the elasticsearch user |

---

## License

MIT
