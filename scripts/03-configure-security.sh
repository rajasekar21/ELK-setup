#!/usr/bin/env bash
# =============================================================================
# ELK Security Configuration — RHEL 9
# Sets passwords for built-in users and stores them in Logstash/Kibana keystores
# Run AFTER 02-generate-certs.sh, as root, with Elasticsearch running
# =============================================================================
set -euo pipefail

ES_HOME="/usr/share/elasticsearch"
LOGSTASH_HOME="/usr/share/logstash"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root." >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Start Elasticsearch and wait for it to be ready
# --------------------------------------------------------------------------- #
echo "==> Starting Elasticsearch..."
systemctl start elasticsearch
echo -n "==> Waiting for Elasticsearch to become available"
for i in {1..30}; do
  if curl -sk https://localhost:9200 -o /dev/null 2>&1; then
    echo " OK"
    break
  fi
  echo -n "."
  sleep 5
done

# --------------------------------------------------------------------------- #
# 2. Set passwords for built-in users (interactive prompt)
# --------------------------------------------------------------------------- #
echo ""
echo "==> Setting passwords for built-in Elasticsearch users..."
echo "    You will be prompted for each password."
echo ""
"$ES_HOME/bin/elasticsearch-setup-passwords" interactive \
  --url https://localhost:9200

# --------------------------------------------------------------------------- #
# 3. Store Logstash passwords in keystore
# --------------------------------------------------------------------------- #
echo ""
echo "==> Configuring Logstash keystore..."
if ! /usr/share/logstash/bin/logstash-keystore list 2>/dev/null | grep -q "LOGSTASH"; then
  /usr/share/logstash/bin/logstash-keystore create
fi

echo "Enter the password you set for 'logstash_system' when prompted:"
/usr/share/logstash/bin/logstash-keystore add LOGSTASH_SYSTEM_PASSWORD

echo "Enter the password for 'logstash_internal' user (create this user in Kibana > Management > Users):"
/usr/share/logstash/bin/logstash-keystore add LOGSTASH_INTERNAL_PASSWORD

# --------------------------------------------------------------------------- #
# 4. Store Kibana password in keystore
# --------------------------------------------------------------------------- #
echo ""
echo "==> Configuring Kibana keystore..."
/usr/share/kibana/bin/kibana-keystore create 2>/dev/null || true

echo "Enter the password you set for 'kibana_system':"
/usr/share/kibana/bin/kibana-keystore add elasticsearch.password

echo "Enter a random 32-char string for KIBANA_ENCRYPTION_KEY:"
/usr/share/kibana/bin/kibana-keystore add xpack.encryptedSavedObjects.encryptionKey

echo "Enter a random 32-char string for KIBANA_REPORTING_KEY:"
/usr/share/kibana/bin/kibana-keystore add xpack.reporting.encryptionKey

# --------------------------------------------------------------------------- #
# 5. Create Logstash internal role and user in Elasticsearch
# --------------------------------------------------------------------------- #
echo ""
echo "==> Creating logstash_internal role and user..."
read -rsp "Enter the elastic superuser password: " ELASTIC_PASS; echo

curl -sk -X PUT "https://localhost:9200/_security/role/logstash_writer" \
  -u "elastic:${ELASTIC_PASS}" \
  -H "Content-Type: application/json" \
  -d '{
    "cluster": ["manage_index_templates","monitor","manage_ilm"],
    "indices": [{
      "names": ["*"],
      "privileges": ["write","create","create_index","manage","manage_ilm"]
    }]
  }'

echo ""
echo "Logstash internal user password:"
read -rsp "Enter password for logstash_internal: " LOGSTASH_INTERNAL_PASS; echo

curl -sk -X PUT "https://localhost:9200/_security/user/logstash_internal" \
  -u "elastic:${ELASTIC_PASS}" \
  -H "Content-Type: application/json" \
  -d "{
    \"password\": \"${LOGSTASH_INTERNAL_PASS}\",
    \"roles\": [\"logstash_writer\"],
    \"full_name\": \"Logstash Internal User\"
  }"

echo ""
echo "============================================================"
echo " Security configuration complete!"
echo " Next step: run ./04-start-services.sh"
echo "============================================================"
