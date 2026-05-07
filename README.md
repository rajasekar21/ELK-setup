# ELK Stack on RHEL 9

Production-ready configuration for Elasticsearch 8.x, Logstash 8.x, Kibana 8.x, and Filebeat 8.x on Red Hat Enterprise Linux 9.

## Architecture

```
[Application / System Logs]
          │
          ▼
     [Filebeat]          ← lightweight log shipper on each host
          │  (TLS/Beats protocol :5044)
          ▼
     [Logstash]          ← parse, enrich, route
          │  (HTTPS :9200)
          ▼
  [Elasticsearch]        ← store and index
          │  (HTTPS :9200)
          ▼
      [Kibana]           ← visualise and alert (:5601)
```

## Prerequisites

| Requirement | Minimum |
|---|---|
| OS | RHEL 9 (or Rocky/Alma Linux 9) |
| RAM | 8 GB (16 GB recommended) |
| CPU | 4 vCPUs |
| Disk | 100 GB (data volume) |
| Java | Bundled with Elasticsearch; JDK 17 for Logstash |
| Ports | 9200, 9300, 5601, 5044, 9600 |

## Directory Structure

```
ELK-setup/
├── elasticsearch/
│   ├── elasticsearch.yml          # Main Elasticsearch config
│   └── jvm.options.d/
│       └── heap.options           # JVM heap size (adjust to your RAM)
├── logstash/
│   ├── logstash.yml               # Main Logstash config
│   └── conf.d/
│       ├── 01-beats-input.conf    # Beats TLS input
│       ├── 10-syslog-filter.conf  # Grok / geoip filters
│       └── 99-elasticsearch-output.conf  # ES output with ILM
├── kibana/
│   └── kibana.yml                 # Main Kibana config
├── filebeat/
│   └── filebeat.yml               # Filebeat log shipper config
└── scripts/
    ├── 01-install-elk.sh          # Install all components
    ├── 02-generate-certs.sh       # Generate TLS certs via certutil
    ├── 03-configure-security.sh   # Set passwords, keystores
    ├── 04-start-services.sh       # Enable services + firewall
    ├── 05-ilm-policy.sh           # Create ILM policy + index template
    └── 06-health-check.sh         # Verify the stack is healthy
```

## Installation

Run each script **as root** in order:

```bash
# 1. Install packages and deploy config files
sudo bash scripts/01-install-elk.sh

# 2. Generate TLS certificates for all components
sudo bash scripts/02-generate-certs.sh

# 3. Set built-in user passwords and configure keystores
sudo bash scripts/03-configure-security.sh

# 4. Open firewall ports and start all services
sudo bash scripts/04-start-services.sh

# 5. Apply ILM retention policy and index template
sudo bash scripts/05-ilm-policy.sh

# 6. Verify everything is healthy
sudo bash scripts/06-health-check.sh
```

## Configuration Reference

### Elasticsearch (`elasticsearch/elasticsearch.yml`)

| Key | Default | Description |
|---|---|---|
| `cluster.name` | `elk-cluster` | Cluster identifier |
| `node.name` | `node-1` | Node identifier |
| `network.host` | `0.0.0.0` | Bind address |
| `http.port` | `9200` | REST API port |
| `discovery.type` | `single-node` | Change to seed-based for multi-node |
| `xpack.security.enabled` | `true` | TLS + authentication enforced |

### JVM Heap (`elasticsearch/jvm.options.d/heap.options`)

Set `-Xms` and `-Xmx` to **half of available RAM**, maximum **31g**:

```
-Xms8g
-Xmx8g
```

### Logstash Pipeline (`logstash/conf.d/`)

| File | Purpose |
|---|---|
| `01-beats-input.conf` | Accept Filebeat events on port 5044 over mTLS |
| `10-syslog-filter.conf` | Parse syslog, nginx access logs; add GeoIP |
| `99-elasticsearch-output.conf` | Route to ES with ILM; parse-failures to separate index |

### Filebeat (`filebeat/filebeat.yml`)

Default inputs collected:

| Log source | Path |
|---|---|
| System syslog | `/var/log/messages`, `/var/log/secure` |
| Audit log | `/var/log/audit/audit.log` |
| Nginx | `/var/log/nginx/{access,error}.log` |
| Application | `/var/log/app/*.log` |

To add more inputs, add a new `filestream` block in `filebeat.yml` and redeploy.

### ILM Retention (`scripts/05-ilm-policy.sh`)

| Phase | Trigger | Action |
|---|---|---|
| Hot | immediately | rollover at 50 GB or 1 day |
| Warm | after 3 days | shrink to 1 shard, forcemerge |
| Cold | after 30 days | freeze index |
| Delete | after 90 days | delete index |

Adjust `min_age` values to match your retention requirements.

## Multi-Node Cluster

To scale to multiple nodes, in `elasticsearch.yml`:

1. Comment out `discovery.type: single-node`
2. Uncomment and populate:
   ```yaml
   discovery.seed_hosts: ["node1-ip", "node2-ip", "node3-ip"]
   cluster.initial_master_nodes: ["node-1", "node-2", "node-3"]
   ```
3. Set `node.name` uniquely on each node
4. Regenerate certificates with all node IPs/hostnames included

## Security Notes

- All inter-component communication is encrypted with TLS.
- Passwords are stored in component keystores (never in YAML files).
- The `.gitignore` excludes `*.p12`, `*.key`, and `*.pem` — **never commit certificates or passwords**.
- Run Kibana behind an HTTPS reverse proxy (nginx/HAProxy) in production.
- Enable SELinux in enforcing mode; `scripts/04-start-services.sh` adds the required port labels.

## Troubleshooting

```bash
# View logs
journalctl -u elasticsearch -f
journalctl -u logstash      -f
journalctl -u kibana        -f
journalctl -u filebeat      -f

# Test Logstash config syntax
/usr/share/logstash/bin/logstash --config.test_and_exit -f /etc/logstash/conf.d/

# Test Filebeat config
filebeat test config -c /etc/filebeat/filebeat.yml
filebeat test output -c /etc/filebeat/filebeat.yml

# Check Elasticsearch cluster health
curl -sk -u elastic https://localhost:9200/_cluster/health?pretty
```

## License

MIT
