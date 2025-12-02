#!/usr/bin/env python3
"""
VPN Metrics Exporter for Prometheus
Exports WireGuard and IPsec VPN metrics in Prometheus format.
"""

import os
import re
import subprocess
import time
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Dict, List, Optional, Tuple

# Configuration
EXPORTER_PORT = int(os.environ.get('EXPORTER_PORT', 9100))
WIREGUARD_INTERFACE = os.environ.get('WIREGUARD_INTERFACE', 'wg0')
IPSEC_CHECK = os.environ.get('IPSEC_CHECK', 'true').lower() == 'true'
COLLECT_INTERVAL = int(os.environ.get('COLLECT_INTERVAL', 10))


class VPNMetrics:
    """Collects VPN metrics from WireGuard and IPsec."""
    
    def __init__(self):
        self.metrics: Dict[str, float] = {}
        self.labels: Dict[str, Dict[str, str]] = {}
    
    def collect_wireguard_metrics(self) -> List[str]:
        """Collect WireGuard interface and peer metrics."""
        metrics = []
        
        try:
            # Get WireGuard interface stats using 'wg show'
            result = subprocess.run(
                ['wg', 'show', WIREGUARD_INTERFACE, 'dump'],
                capture_output=True, text=True, timeout=5
            )
            
            if result.returncode == 0:
                lines = result.stdout.strip().split('\n')
                
                # First line is interface info
                if lines:
                    interface_parts = lines[0].split('\t')
                    metrics.append(f'vpn_tunnel_status{{vpn_type="wireguard",interface="{WIREGUARD_INTERFACE}"}} 1')
                    
                    # Peer lines follow
                    for line in lines[1:]:
                        parts = line.split('\t')
                        if len(parts) >= 8:
                            public_key = parts[0][:12] + "..."  # Truncate for label
                            endpoint = parts[2] if parts[2] != "(none)" else "unknown"
                            rx_bytes = parts[5]
                            tx_bytes = parts[6]
                            latest_handshake = parts[4]
                            
                            metrics.append(
                                f'wireguard_peer_receive_bytes_total{{interface="{WIREGUARD_INTERFACE}",'
                                f'public_key="{public_key}",endpoint="{endpoint}"}} {rx_bytes}'
                            )
                            metrics.append(
                                f'wireguard_peer_transmit_bytes_total{{interface="{WIREGUARD_INTERFACE}",'
                                f'public_key="{public_key}",endpoint="{endpoint}"}} {tx_bytes}'
                            )
                            metrics.append(
                                f'wireguard_peer_last_handshake_seconds{{interface="{WIREGUARD_INTERFACE}",'
                                f'public_key="{public_key}"}} {latest_handshake}'
                            )
            else:
                metrics.append(f'vpn_tunnel_status{{vpn_type="wireguard",interface="{WIREGUARD_INTERFACE}"}} 0')
                
        except FileNotFoundError:
            # WireGuard not installed
            metrics.append(f'vpn_tunnel_status{{vpn_type="wireguard",interface="{WIREGUARD_INTERFACE}"}} 0')
            metrics.append(f'vpn_exporter_error{{vpn_type="wireguard",error="wg_not_found"}} 1')
        except subprocess.TimeoutExpired:
            metrics.append(f'vpn_exporter_error{{vpn_type="wireguard",error="timeout"}} 1')
        except Exception as e:
            metrics.append(f'vpn_exporter_error{{vpn_type="wireguard",error="exception"}} 1')
        
        return metrics
    
    def collect_ipsec_metrics(self) -> List[str]:
        """Collect IPsec/Strongswan metrics."""
        metrics = []
        
        if not IPSEC_CHECK:
            return metrics
        
        try:
            # Check IPsec SA status using 'ipsec statusall'
            result = subprocess.run(
                ['ipsec', 'statusall'],
                capture_output=True, text=True, timeout=10
            )
            
            if result.returncode == 0:
                output = result.stdout
                
                # Parse connection status
                established = output.count('ESTABLISHED')
                installed = output.count('INSTALLED')
                
                metrics.append(f'vpn_tunnel_status{{vpn_type="ipsec"}} {1 if established > 0 else 0}')
                metrics.append(f'ipsec_connections_established {established}')
                metrics.append(f'ipsec_sas_installed {installed}')
                
                # Parse byte counts from ipsec status
                # Example: "bytes_i (123456s ago), 789012 bytes_o"
                rx_match = re.search(r'(\d+)\s+bytes_i', output)
                tx_match = re.search(r'(\d+)\s+bytes_o', output)
                
                if rx_match:
                    metrics.append(f'ipsec_receive_bytes_total {rx_match.group(1)}')
                if tx_match:
                    metrics.append(f'ipsec_transmit_bytes_total {tx_match.group(1)}')
                    
            else:
                metrics.append(f'vpn_tunnel_status{{vpn_type="ipsec"}} 0')
                
        except FileNotFoundError:
            metrics.append(f'vpn_tunnel_status{{vpn_type="ipsec"}} 0')
            metrics.append(f'vpn_exporter_error{{vpn_type="ipsec",error="ipsec_not_found"}} 1')
        except subprocess.TimeoutExpired:
            metrics.append(f'vpn_exporter_error{{vpn_type="ipsec",error="timeout"}} 1')
        except Exception as e:
            metrics.append(f'vpn_exporter_error{{vpn_type="ipsec",error="exception"}} 1')
        
        return metrics
    
    def collect_network_interface_metrics(self) -> List[str]:
        """Collect network interface metrics from /proc/net/dev."""
        metrics = []
        interfaces_of_interest = ['wg0', 'wg1', 'ipsec0', 'eth0', 'ens', 'enp']
        
        try:
            with open('/proc/net/dev', 'r') as f:
                lines = f.readlines()[2:]  # Skip header lines
                
            for line in lines:
                parts = line.split(':')
                if len(parts) != 2:
                    continue
                    
                iface = parts[0].strip()
                
                # Check if interface is of interest
                if not any(iface.startswith(prefix) for prefix in interfaces_of_interest):
                    continue
                
                stats = parts[1].split()
                if len(stats) >= 16:
                    rx_bytes = stats[0]
                    rx_packets = stats[1]
                    rx_errors = stats[2]
                    rx_drops = stats[3]
                    tx_bytes = stats[8]
                    tx_packets = stats[9]
                    tx_errors = stats[10]
                    tx_drops = stats[11]
                    
                    metrics.append(f'vpn_interface_rx_bytes{{interface="{iface}"}} {rx_bytes}')
                    metrics.append(f'vpn_interface_tx_bytes{{interface="{iface}"}} {tx_bytes}')
                    metrics.append(f'vpn_interface_rx_packets{{interface="{iface}"}} {rx_packets}')
                    metrics.append(f'vpn_interface_tx_packets{{interface="{iface}"}} {tx_packets}')
                    metrics.append(f'vpn_interface_rx_errors{{interface="{iface}"}} {rx_errors}')
                    metrics.append(f'vpn_interface_tx_errors{{interface="{iface}"}} {tx_errors}')
                    
        except Exception as e:
            metrics.append(f'vpn_exporter_error{{component="network",error="proc_read_failed"}} 1')
        
        return metrics
    
    def collect_latency_metrics(self) -> List[str]:
        """Collect latency metrics via ping tests."""
        metrics = []
        
        # These would be the VPN tunnel endpoints - adjust as needed
        targets = [
            ('10.10.10.2', 'wireguard'),  # WireGuard peer
            # Add IPsec peer if applicable
        ]
        
        for target, vpn_type in targets:
            try:
                result = subprocess.run(
                    ['ping', '-c', '3', '-W', '2', target],
                    capture_output=True, text=True, timeout=10
                )
                
                if result.returncode == 0:
                    # Parse average latency from ping output
                    match = re.search(r'avg[^=]+=\s*[\d.]+/([\d.]+)/', result.stdout)
                    if match:
                        latency = float(match.group(1))
                        metrics.append(f'vpn_latency_ms{{vpn_type="{vpn_type}",target="{target}"}} {latency}')
                        
            except (subprocess.TimeoutExpired, Exception):
                pass
        
        return metrics
    
    def collect_all(self) -> str:
        """Collect all metrics and return Prometheus format."""
        all_metrics = []
        
        # Add metric help/type annotations
        all_metrics.append('# HELP vpn_tunnel_status VPN tunnel status (1=up, 0=down)')
        all_metrics.append('# TYPE vpn_tunnel_status gauge')
        
        all_metrics.append('# HELP wireguard_peer_receive_bytes_total Total bytes received from WireGuard peer')
        all_metrics.append('# TYPE wireguard_peer_receive_bytes_total counter')
        
        all_metrics.append('# HELP wireguard_peer_transmit_bytes_total Total bytes sent to WireGuard peer')
        all_metrics.append('# TYPE wireguard_peer_transmit_bytes_total counter')
        
        all_metrics.append('# HELP vpn_latency_ms VPN tunnel latency in milliseconds')
        all_metrics.append('# TYPE vpn_latency_ms gauge')
        
        all_metrics.append('# HELP vpn_interface_rx_bytes Network interface received bytes')
        all_metrics.append('# TYPE vpn_interface_rx_bytes counter')
        
        all_metrics.append('# HELP vpn_interface_tx_bytes Network interface transmitted bytes')
        all_metrics.append('# TYPE vpn_interface_tx_bytes counter')
        
        all_metrics.append('# HELP ipsec_connections_established Number of established IPsec connections')
        all_metrics.append('# TYPE ipsec_connections_established gauge')
        
        # Collect metrics
        all_metrics.extend(self.collect_wireguard_metrics())
        all_metrics.extend(self.collect_ipsec_metrics())
        all_metrics.extend(self.collect_network_interface_metrics())
        all_metrics.extend(self.collect_latency_metrics())
        
        # Add exporter info
        all_metrics.append(f'# HELP vpn_exporter_info VPN metrics exporter info')
        all_metrics.append(f'# TYPE vpn_exporter_info gauge')
        all_metrics.append(f'vpn_exporter_info{{version="1.0.0"}} 1')
        all_metrics.append(f'vpn_exporter_scrape_timestamp {int(time.time())}')
        
        return '\n'.join(all_metrics) + '\n'


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics endpoint."""
    
    metrics_collector = VPNMetrics()
    
    def do_GET(self):
        if self.path == '/metrics':
            metrics = self.metrics_collector.collect_all()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(metrics.encode('utf-8'))
        elif self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress default logging for cleaner output
        pass


def main():
    """Start the metrics exporter HTTP server."""
    print(f"Starting VPN Metrics Exporter on port {EXPORTER_PORT}")
    print(f"  WireGuard interface: {WIREGUARD_INTERFACE}")
    print(f"  IPsec check enabled: {IPSEC_CHECK}")
    print(f"Metrics available at http://localhost:{EXPORTER_PORT}/metrics")
    
    server = HTTPServer(('0.0.0.0', EXPORTER_PORT), MetricsHandler)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
