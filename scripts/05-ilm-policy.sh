#!/usr/bin/env bash
# =============================================================================
# Index Lifecycle Management (ILM) Policy Setup — RHEL 9 ELK Stack
# Creates a default ILM policy and index template
# =============================================================================
set -euo pipefail

read -rsp "Enter elastic password: " ELASTIC_PASS; echo
ES_URL="https://localhost:9200"
CURL="curl -sk -u elastic:${ELASTIC_PASS} -H Content-Type:application/json"

# --------------------------------------------------------------------------- #
# 1. Default ILM policy
# --------------------------------------------------------------------------- #
echo "==> Creating default-ilm-policy..."
$CURL -X PUT "$ES_URL/_ilm/policy/default-ilm-policy" -d '{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "1d"
          },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "3d",
        "actions": {
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 },
          "set_priority": { "priority": 50 }
        }
      },
      "cold": {
        "min_age": "30d",
        "actions": {
          "set_priority": { "priority": 0 },
          "freeze": {}
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}'
echo ""

# --------------------------------------------------------------------------- #
# 2. Index template for Filebeat/Beats indices
# --------------------------------------------------------------------------- #
echo "==> Creating filebeat index template..."
$CURL -X PUT "$ES_URL/_index_template/filebeat-template" -d '{
  "index_patterns": ["filebeat-*", "logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.lifecycle.name": "default-ilm-policy",
      "index.lifecycle.rollover_alias": "filebeat"
    },
    "mappings": {
      "dynamic_templates": [
        {
          "strings_as_keyword": {
            "match_mapping_type": "string",
            "mapping": { "type": "keyword", "ignore_above": 1024 }
          }
        }
      ],
      "properties": {
        "@timestamp":    { "type": "date" },
        "message":       { "type": "text" },
        "log.level":     { "type": "keyword" },
        "host.name":     { "type": "keyword" },
        "source.ip":     { "type": "ip" },
        "geoip": {
          "properties": {
            "location": { "type": "geo_point" }
          }
        }
      }
    }
  },
  "priority": 200
}'
echo ""

# --------------------------------------------------------------------------- #
# 3. Bootstrap the filebeat write alias
# --------------------------------------------------------------------------- #
echo "==> Bootstrapping filebeat index and alias..."
$CURL -X PUT "$ES_URL/%3Cfilebeat-%7Bnow%2Fd%7D-000001%3E" -d '{
  "aliases": {
    "filebeat": { "is_write_index": true }
  }
}'
echo ""

echo "============================================================"
echo " ILM policy and index template applied!"
echo "============================================================"
