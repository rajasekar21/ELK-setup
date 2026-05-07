#!/usr/bin/env bash
# =============================================================================
# ELK Stack Installation Script — RHEL 9
# Installs: Elasticsearch 8.x, Logstash 8.x, Kibana 8.x, Filebeat 8.x
# Run as root or with sudo
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
  firewalld

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
# 4. System tuning for Elasticsearch
# --------------------------------------------------------------------------- #
echo "==> Applying system tuning..."

# vm.max_map_count required by Elasticsearch
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.d/99-elasticsearch.conf

# File descriptor and thread limits
cat >> /etc/security/limits.d/99-elasticsearch.conf << 'LIMITS'
elasticsearch soft nofile 65535
elasticsearch hard nofile 65535
elasticsearch soft nproc  4096
elasticsearch hard nproc  4096
elasticsearch soft memlock unlimited
elasticsearch hard memlock unlimited
LIMITS

# Allow memory lock for Elasticsearch systemd unit
mkdir -p /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/override.conf << 'OVERRIDE'
[Service]
LimitMEMLOCK=infinity
OVERRIDE

systemctl daemon-reload

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
