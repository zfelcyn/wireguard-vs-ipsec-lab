# Prometheus + Grafana Monitoring Stack

This monitoring stack provides real-time visualization and metrics collection for comparing WireGuard and IPsec VPN performance.

## Quick Start

```bash
# Start the monitoring stack
make mon-up

# Access the dashboards
# Grafana:    http://localhost:3000  (admin/vpnlab123)
# Prometheus: http://localhost:9090
# Pushgateway: http://localhost:9091
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Monitoring Stack                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐         │
│  │   Grafana    │◄────│  Prometheus  │◄────│  Pushgateway │         │
│  │  (Dashboard) │     │  (Metrics DB)│     │ (Batch Jobs) │         │
│  │  :3000       │     │  :9090       │     │  :9091       │         │
│  └──────────────┘     └──────┬───────┘     └──────────────┘         │
│                              │                     ▲                 │
│                              │                     │                 │
│         ┌────────────────────┼────────────────┐   │                 │
│         │                    │                │   │                 │
│         ▼                    ▼                ▼   │                 │
│  ┌─────────────┐     ┌─────────────┐   ┌──────────┴──┐              │
│  │VPN Exporter │     │Node Exporter│   │ iperf Test  │              │
│  │ (WG/IPsec)  │     │(System Stats)   │  Script     │              │
│  │ :9100       │     │ :9101/:9102 │   └─────────────┘              │
│  └─────────────┘     └─────────────┘                                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Port | Description |
|-----------|------|-------------|
| Grafana | 3000 | Dashboard visualization |
| Prometheus | 9090 | Metrics collection & storage |
| Pushgateway | 9091 | Receive metrics from batch jobs |
| VPN Exporter | 9100 | Custom WireGuard/IPsec metrics |
| Node Exporter A | 9101 | System metrics (Network A) |
| Node Exporter B | 9102 | System metrics (Network B) |

## Available Metrics

### VPN Tunnel Metrics
- `vpn_tunnel_status` - Tunnel status (1=up, 0=down)
- `vpn_latency_ms` - Tunnel latency in milliseconds
- `vpn_iperf_throughput_mbps` - iperf3 measured throughput

### WireGuard Metrics
- `wireguard_peer_receive_bytes_total` - Bytes received from peer
- `wireguard_peer_transmit_bytes_total` - Bytes sent to peer
- `wireguard_peer_last_handshake_seconds` - Time since last handshake

### IPsec Metrics
- `ipsec_connections_established` - Number of established connections
- `ipsec_sas_installed` - Number of installed SAs
- `ipsec_receive_bytes_total` - Total received bytes
- `ipsec_transmit_bytes_total` - Total transmitted bytes

### Network Interface Metrics
- `vpn_interface_rx_bytes` - Interface received bytes
- `vpn_interface_tx_bytes` - Interface transmitted bytes
- `vpn_interface_rx_packets` - Interface received packets
- `vpn_interface_tx_packets` - Interface transmitted packets

## Running Performance Tests

### Test WireGuard Throughput
```bash
# Run test and push to Prometheus
make perf-wg HOST=10.10.10.2

# Or manually:
python3 testbed/monitoring/exporter/push_iperf_metrics.py \
    --vpn-type wireguard \
    --host 10.10.10.2 \
    --duration 30 \
    --latency-test
```

### Test IPsec Throughput
```bash
# Run test and push to Prometheus
make perf-ipsec HOST=10.0.2.10

# Or manually:
python3 testbed/monitoring/exporter/push_iperf_metrics.py \
    --vpn-type ipsec \
    --host 10.0.2.10 \
    --duration 30 \
    --latency-test
```

### Run Comparison Test
```bash
make perf-compare WG_HOST=10.10.10.2 IPSEC_HOST=10.0.2.10
```

## Grafana Dashboard

The pre-configured dashboard includes:

1. **Overview Panel** - Current throughput and latency for both VPNs
2. **Throughput Comparison** - Time-series graph comparing WireGuard vs IPsec
3. **Latency Comparison** - Time-series latency graph
4. **Network Interface Stats** - Raw interface traffic
5. **CPU Usage** - System CPU during tests
6. **Tunnel Status** - UP/DOWN indicators
7. **Test Results History** - Table of past test runs

### Accessing the Dashboard

1. Open http://localhost:3000
2. Login with `admin` / `vpnlab123`
3. Navigate to "VPN Performance" folder
4. Open "WireGuard vs IPsec Performance" dashboard

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EXPORTER_PORT` | 9100 | VPN exporter listen port |
| `WIREGUARD_INTERFACE` | wg0 | WireGuard interface name |
| `IPSEC_CHECK` | true | Enable IPsec metrics collection |

### Customizing Prometheus

Edit `testbed/monitoring/prometheus/prometheus.yml`:

```yaml
scrape_configs:
  # Add your custom targets
  - job_name: 'my-custom-exporter'
    static_configs:
      - targets: ['my-host:9100']
```

## Troubleshooting

### Grafana shows "No Data"

1. Check Prometheus is running: http://localhost:9090
2. Verify targets are up: http://localhost:9090/targets
3. Run a performance test to generate metrics:
   ```bash
   make perf-wg HOST=<your-wireguard-peer>
   ```

### VPN Exporter shows tunnel down

The exporter needs access to the `wg` and `ipsec` commands. In Docker, you may need to run with host network mode:

```yaml
# In docker-compose.monitoring.yaml
vpn-exporter:
  network_mode: host
```

### Reset monitoring data

```bash
make mon-down
docker volume rm wireguard-vs-ipsec-lab_prometheus-data
docker volume rm wireguard-vs-ipsec-lab_grafana-data
make mon-up
```

## Files Structure

```
testbed/
├── docker-compose.monitoring.yaml   # Docker compose for stack
└── monitoring/
    ├── prometheus/
    │   └── prometheus.yml           # Prometheus config
    ├── grafana/
    │   └── provisioning/
    │       ├── datasources/
    │       │   └── datasources.yml  # Auto-configure Prometheus
    │       └── dashboards/
    │           ├── dashboards.yml   # Dashboard provisioning
    │           └── vpn-performance.json  # Main dashboard
    └── exporter/
        ├── Dockerfile               # Custom exporter container
        ├── vpn_exporter.py          # VPN metrics exporter
        └── push_iperf_metrics.py    # Push iperf results
```
