#!/usr/bin/env bash
# =============================================================================
# Enable & Start ELK Services — RHEL 9
# Configures firewall and starts all ELK services
# Run as root after security configuration
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root." >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Configure firewalld
# --------------------------------------------------------------------------- #
echo "==> Configuring firewall rules..."
systemctl enable --now firewalld

firewall-cmd --permanent --add-port=9200/tcp   # Elasticsearch HTTP
firewall-cmd --permanent --add-port=9300/tcp   # Elasticsearch transport
firewall-cmd --permanent --add-port=5601/tcp   # Kibana
firewall-cmd --permanent --add-port=5044/tcp   # Logstash Beats input
firewall-cmd --permanent --add-port=9600/tcp   # Logstash HTTP API
firewall-cmd --reload

# --------------------------------------------------------------------------- #
# 2. SELinux — allow Elasticsearch and Kibana ports
# --------------------------------------------------------------------------- #
echo "==> Configuring SELinux..."
if command -v semanage &>/dev/null; then
  semanage port -a -t http_port_t -p tcp 9200 2>/dev/null || semanage port -m -t http_port_t -p tcp 9200
  semanage port -a -t http_port_t -p tcp 5601 2>/dev/null || semanage port -m -t http_port_t -p tcp 5601
  semanage port -a -t syslogd_port_t -p tcp 5044 2>/dev/null || semanage port -m -t syslogd_port_t -p tcp 5044
else
  echo "WARNING: semanage not found — install policycoreutils-python-utils if SELinux is enforcing"
fi

# --------------------------------------------------------------------------- #
# 3. Enable and start services in order
# --------------------------------------------------------------------------- #
declare -a SERVICES=("elasticsearch" "logstash" "kibana" "filebeat")

for svc in "${SERVICES[@]}"; do
  echo "==> Enabling and starting ${svc}..."
  systemctl enable "$svc"
  systemctl start  "$svc"
done

# --------------------------------------------------------------------------- #
# 4. Health check
# --------------------------------------------------------------------------- #
echo ""
echo "==> Waiting 15 seconds for services to stabilize..."
sleep 15

echo ""
echo "==> Service status:"
for svc in "${SERVICES[@]}"; do
  status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
  printf "  %-20s %s\n" "$svc" "$status"
done

echo ""
echo "==> Elasticsearch cluster health:"
curl -sk -u elastic https://localhost:9200/_cluster/health?pretty || true

echo ""
echo "============================================================"
echo " ELK Stack is running!"
echo " Kibana UI: https://$(hostname -I | awk '{print $1}'):5601"
echo " Login with: elastic / <your elastic password>"
echo "============================================================"
