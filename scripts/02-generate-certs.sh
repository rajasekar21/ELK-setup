#!/usr/bin/env bash
# =============================================================================
# TLS Certificate Generation — RHEL 9 ELK Stack
# Uses elasticsearch-certutil (bundled with Elasticsearch)
# Run AFTER 01-install-elk.sh, as root
# =============================================================================
set -euo pipefail

CERT_DIR="/etc/elasticsearch/certs"
ES_HOME="/usr/share/elasticsearch"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"

# --------------------------------------------------------------------------- #
# 1. Generate CA
# --------------------------------------------------------------------------- #
echo "==> Generating Certificate Authority..."
"$ES_HOME/bin/elasticsearch-certutil" ca \
  --silent \
  --out "$CERT_DIR/elastic-stack-ca.p12" \
  --pass ""

# Export CA cert in PEM format (needed by Logstash, Kibana, Filebeat)
"$ES_HOME/bin/elasticsearch-certutil" \
  cert \
  --silent \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --out "$CERT_DIR/elastic-certificates.p12" \
  --pass ""

openssl pkcs12 -in "$CERT_DIR/elastic-stack-ca.p12" \
  -nokeys -passin pass:"" \
  | openssl x509 -out "$CERT_DIR/ca.crt"

# --------------------------------------------------------------------------- #
# 2. Generate Elasticsearch node certificate
# --------------------------------------------------------------------------- #
echo "==> Generating Elasticsearch certificate..."
"$ES_HOME/bin/elasticsearch-certutil" cert \
  --silent \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --name elasticsearch \
  --out "$CERT_DIR/elasticsearch.p12" \
  --pass "" \
  --dns "$(hostname)" \
  --ip "$(hostname -I | awk '{print $1}')"

# --------------------------------------------------------------------------- #
# 3. Generate Logstash certificate (PEM format)
# --------------------------------------------------------------------------- #
echo "==> Generating Logstash certificate..."
LOGSTASH_CERT_DIR="/etc/logstash/certs"
mkdir -p "$LOGSTASH_CERT_DIR"

"$ES_HOME/bin/elasticsearch-certutil" cert \
  --silent \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --name logstash \
  --out "/tmp/logstash.p12" \
  --pass ""

openssl pkcs12 -in /tmp/logstash.p12 -nocerts -nodes -passin pass:"" \
  -out "$LOGSTASH_CERT_DIR/logstash.key"
openssl pkcs12 -in /tmp/logstash.p12 -nokeys -passin pass:"" \
  | openssl x509 -out "$LOGSTASH_CERT_DIR/logstash.crt"
cp "$CERT_DIR/ca.crt" "$LOGSTASH_CERT_DIR/ca.crt"
rm -f /tmp/logstash.p12

# --------------------------------------------------------------------------- #
# 4. Generate Kibana certificate
# --------------------------------------------------------------------------- #
echo "==> Generating Kibana certificate..."
KIBANA_CERT_DIR="/etc/kibana/certs"
mkdir -p "$KIBANA_CERT_DIR"

"$ES_HOME/bin/elasticsearch-certutil" cert \
  --silent \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --name kibana \
  --out "/tmp/kibana.p12" \
  --pass ""

openssl pkcs12 -in /tmp/kibana.p12 -nocerts -nodes -passin pass:"" \
  -out "$KIBANA_CERT_DIR/kibana.key"
openssl pkcs12 -in /tmp/kibana.p12 -nokeys -passin pass:"" \
  | openssl x509 -out "$KIBANA_CERT_DIR/kibana.crt"
cp "$CERT_DIR/ca.crt" "$KIBANA_CERT_DIR/ca.crt"
rm -f /tmp/kibana.p12

# --------------------------------------------------------------------------- #
# 5. Generate Filebeat certificate
# --------------------------------------------------------------------------- #
echo "==> Generating Filebeat certificate..."
FILEBEAT_CERT_DIR="/etc/filebeat/certs"
mkdir -p "$FILEBEAT_CERT_DIR"

"$ES_HOME/bin/elasticsearch-certutil" cert \
  --silent \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --name filebeat \
  --out "/tmp/filebeat.p12" \
  --pass ""

openssl pkcs12 -in /tmp/filebeat.p12 -nocerts -nodes -passin pass:"" \
  -out "$FILEBEAT_CERT_DIR/filebeat.key"
openssl pkcs12 -in /tmp/filebeat.p12 -nokeys -passin pass:"" \
  | openssl x509 -out "$FILEBEAT_CERT_DIR/filebeat.crt"
cp "$CERT_DIR/ca.crt" "$FILEBEAT_CERT_DIR/ca.crt"
rm -f /tmp/filebeat.p12

# --------------------------------------------------------------------------- #
# 6. Fix permissions
# --------------------------------------------------------------------------- #
echo "==> Setting permissions..."
chown -R root:elasticsearch "$CERT_DIR"
chmod 750 "$CERT_DIR"
chmod 640 "$CERT_DIR"/*.{p12,crt} 2>/dev/null || true

chown -R root:logstash  "$LOGSTASH_CERT_DIR"  && chmod 750 "$LOGSTASH_CERT_DIR"
chown -R root:kibana    "$KIBANA_CERT_DIR"     && chmod 750 "$KIBANA_CERT_DIR"
chown -R root:root      "$FILEBEAT_CERT_DIR"   && chmod 750 "$FILEBEAT_CERT_DIR"

chmod 640 \
  "$LOGSTASH_CERT_DIR"/*.{crt,key} \
  "$KIBANA_CERT_DIR"/*.{crt,key}   \
  "$FILEBEAT_CERT_DIR"/*.{crt,key} 2>/dev/null || true

echo ""
echo "============================================================"
echo " Certificates generated successfully!"
echo " Next step: run ./03-configure-security.sh"
echo "============================================================"
