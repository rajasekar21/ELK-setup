#!/usr/bin/env bash
# =============================================================================
# ELK Stack Health Check — RHEL 9
# =============================================================================
set -euo pipefail

read -rsp "Enter elastic password: " ELASTIC_PASS; echo
ES="https://localhost:9200"
AUTH="elastic:${ELASTIC_PASS}"

echo ""
echo "===== Service Status =================================================="
for svc in elasticsearch logstash kibana filebeat; do
  printf "  %-20s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo 'not-found')"
done

echo ""
echo "===== Elasticsearch Cluster Health ======================================"
curl -sk -u "$AUTH" "$ES/_cluster/health?pretty"

echo ""
echo "===== Elasticsearch Nodes ==============================================="
curl -sk -u "$AUTH" "$ES/_cat/nodes?v"

echo ""
echo "===== Elasticsearch Indices ============================================="
curl -sk -u "$AUTH" "$ES/_cat/indices?v&s=index"

echo ""
echo "===== Logstash Pipeline Stats ==========================================="
curl -sk http://localhost:9600/_node/stats/pipelines?pretty | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {k}: in={v[\"events\"][\"in\"]} out={v[\"events\"][\"out\"]} failed={v[\"events\"][\"filtered\"]}') for k,v in d.get('pipelines',{}).items()]" 2>/dev/null || echo "  (Logstash not reachable or python3 unavailable)"

echo ""
echo "===== Kibana Status ====================================================="
curl -sk "https://localhost:5601/api/status" \
  --cacert /etc/kibana/certs/ca.crt | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  Status: {d[\"status\"][\"overall\"][\"level\"]}')" 2>/dev/null || echo "  (Kibana not reachable)"

echo ""
echo "===== Disk & Memory Usage ==============================================="
df -h /var/lib/elasticsearch /var/lib/logstash 2>/dev/null || true
free -h

echo ""
echo "======================================================================"
echo " Health check complete."
echo "======================================================================"
