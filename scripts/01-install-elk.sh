#!/usr/bin/env bash
# =============================================================================
# ELK Stack Installation Script — RHEL 9 (Bare Metal)
# Installs: Elasticsearch 8.x, Logstash 8.x, Kibana 8.x, Filebeat 8.x
#
# Assumes:
#   - Physical server (no Docker / Kubernetes / hypervisor)
#   - RHEL 9 minimal install with network configured
#   - Dedicated data disk mounted at /var/lib/elasticsearch
#   - Run as root
# =============================================================================
set -euo pipefail

ELK_VERSION="8.13"

# --------------------------------------------------------------------------- #
# 0. Pre-flight checks
# --------------------------------------------------------------------------- #
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

echo "==> Checking OS..."
. /etc/os-release
if [[ "$ID" != "rhel" && "$ID" != "centos" && "$ID" != "rocky" && "$ID" != "almalinux" ]]; then
  echo "WARNING: This script is designed for RHEL 9 variants. Detected: $ID"
fi

# Require RHEL 9.x
if [[ "${VERSION_ID%%.*}" != "9" ]]; then
  echo "ERROR: RHEL 9 required. Detected: $VERSION_ID" >&2
  exit 1
fi

# Confirm this is a physical host (not a container)
if systemd-detect-virt --container &>/dev/null; then
  echo "ERROR: Container environment detected. This script targets bare metal servers." >&2
  exit 1
fi

echo "==> Hardware detected:"
echo "  CPUs   : $(nproc) logical cores"
echo "  RAM    : $(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' /proc/meminfo)"
echo "  Kernel : $(uname -r)"

# --------------------------------------------------------------------------- #
# 1. System prerequisites
# --------------------------------------------------------------------------- #
echo "==> Installing system prerequisites..."
dnf install -y \
  java-17-openjdk-headless \
  curl \
  wget \
  tar \
  gnupg2 \
  net-tools \
  firewalld \
  tuned \
  numactl \
  irqbalance \
  ethtool \
  policycoreutils-python-utils

# Set Java home for ELK (Elasticsearch bundles its own JDK, but Logstash may need it)
echo 'export JAVA_HOME=/usr/lib/jvm/jre-17-openjdk' > /etc/profile.d/java.sh
source /etc/profile.d/java.sh

# --------------------------------------------------------------------------- #
# 2. Add Elastic YUM repository
# --------------------------------------------------------------------------- #
echo "==> Adding Elastic repository..."
rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

cat > /etc/yum.repos.d/elasticsearch.repo << 'REPO'
[elasticsearch]
name=Elasticsearch repository for 8.x packages
baseurl=https://artifacts.elastic.co/packages/8.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
REPO

dnf makecache

# --------------------------------------------------------------------------- #
# 3. Install ELK components
# --------------------------------------------------------------------------- #
echo "==> Installing Elasticsearch..."
dnf install -y elasticsearch

echo "==> Installing Logstash..."
dnf install -y logstash

echo "==> Installing Kibana..."
dnf install -y kibana

echo "==> Installing Filebeat..."
dnf install -y filebeat

# --------------------------------------------------------------------------- #
# 4. Bare metal OS tuning
# --------------------------------------------------------------------------- #
echo "==> Applying bare metal OS tuning..."

# --- 4a. tuned profile (throughput-performance is optimal for ELK on bare metal)
systemctl enable --now tuned
tuned-adm profile throughput-performance
echo "  tuned profile: $(tuned-adm active)"

# --- 4b. Disable Transparent Huge Pages (THP)
# THP causes latency spikes in Elasticsearch's memory allocator
cat > /etc/systemd/system/disable-thp.service << 'THP'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
THP
systemctl daemon-reload
systemctl enable --now disable-thp
echo "  THP disabled"

# --- 4c. CPU governor — set to performance for consistent latency
if ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor &>/dev/null; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$gov"
  done
  echo "  CPU governor: performance"
else
  echo "  WARNING: cpufreq not available — set CPU power policy to 'Performance' in BIOS"
fi

# --- 4d. Kernel / VM parameters
cat > /etc/sysctl.d/99-elk-baremetal.conf << 'SYSCTL'
# Elasticsearch minimum
vm.max_map_count = 262144

# Reduce swappiness — prefer RAM over swap for ELK workloads
vm.swappiness = 1

# Avoid OOM kills on large allocations
vm.overcommit_memory = 1

# Network throughput tuning for high-volume log ingestion
net.core.rmem_max          = 134217728
net.core.wmem_max          = 134217728
net.core.netdev_max_backlog = 300000
net.ipv4.tcp_rmem          = 4096 87380 134217728
net.ipv4.tcp_wmem          = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0

# File system
fs.file-max    = 2097152
fs.inotify.max_user_watches = 524288
SYSCTL
sysctl --system
echo "  Kernel parameters applied"

# --- 4e. I/O scheduler — none/mq-deadline for SSDs/NVMe, deadline for HDDs
DATA_DEV=""
if [[ -d /var/lib/elasticsearch ]]; then
  DATA_DEV=$(df /var/lib/elasticsearch | awk 'NR==2{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
fi
if [[ -n "$DATA_DEV" && -f "/sys/block/${DATA_DEV}/queue/scheduler" ]]; then
  if lsblk -d -o rota "/dev/${DATA_DEV}" 2>/dev/null | grep -q "^0"; then
    echo "none" > "/sys/block/${DATA_DEV}/queue/scheduler"
    echo "  I/O scheduler: none (SSD/NVMe on ${DATA_DEV})"
  else
    echo "mq-deadline" > "/sys/block/${DATA_DEV}/queue/scheduler" 2>/dev/null || true
    echo "  I/O scheduler: mq-deadline (HDD on ${DATA_DEV})"
  fi
  # Persist across reboots via udev
  cat > /etc/udev/rules.d/60-elk-ioscheduler.rules << UDEV
ACTION=="add|change", KERNEL=="${DATA_DEV}", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="${DATA_DEV}", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
UDEV
fi

# --- 4f. IRQ balancing — distribute NIC interrupts across NUMA-aware CPUs
systemctl enable --now irqbalance
echo "  irqbalance enabled"

# --- 4g. File descriptor and thread limits
cat > /etc/security/limits.d/99-elasticsearch.conf << 'LIMITS'
elasticsearch  soft  nofile   1048576
elasticsearch  hard  nofile   1048576
elasticsearch  soft  nproc    65535
elasticsearch  hard  nproc    65535
elasticsearch  soft  memlock  unlimited
elasticsearch  hard  memlock  unlimited
logstash       soft  nofile   131072
logstash       hard  nofile   131072
logstash       soft  nproc    16384
logstash       hard  nproc    16384
LIMITS

# --- 4h. Allow memory lock for Elasticsearch systemd unit
mkdir -p /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/override.conf << 'OVERRIDE'
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=1048576
LimitNPROC=65535
OVERRIDE

systemctl daemon-reload
echo "  systemd limits applied"

# --------------------------------------------------------------------------- #
# 5. Deploy configuration files
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Deploying Elasticsearch config..."
cp "$REPO_ROOT/elasticsearch/elasticsearch.yml" /etc/elasticsearch/elasticsearch.yml
mkdir -p /etc/elasticsearch/jvm.options.d
cp "$REPO_ROOT/elasticsearch/jvm.options.d/heap.options" /etc/elasticsearch/jvm.options.d/heap.options
chown -R root:elasticsearch /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

echo "==> Deploying Logstash config..."
cp "$REPO_ROOT/logstash/logstash.yml" /etc/logstash/logstash.yml
cp "$REPO_ROOT/logstash/conf.d/"*.conf /etc/logstash/conf.d/
chown -R root:logstash /etc/logstash
chmod 660 /etc/logstash/logstash.yml

echo "==> Deploying Kibana config..."
cp "$REPO_ROOT/kibana/kibana.yml" /etc/kibana/kibana.yml
chown -R root:kibana /etc/kibana
chmod 660 /etc/kibana/kibana.yml

echo "==> Deploying Filebeat config..."
cp "$REPO_ROOT/filebeat/filebeat.yml" /etc/filebeat/filebeat.yml
chown root:root /etc/filebeat/filebeat.yml
chmod 600 /etc/filebeat/filebeat.yml

echo ""
echo "============================================================"
echo " Installation complete!"
echo " Next step: run ./02-generate-certs.sh"
echo "============================================================"
