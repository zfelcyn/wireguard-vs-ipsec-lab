#!/usr/bin/env python3
"""
Push iperf3 results to Prometheus Pushgateway.
Run after performance tests to record results in Prometheus.

Usage:
    python push_iperf_metrics.py --vpn-type wireguard --host 10.10.10.2 --duration 30
    python push_iperf_metrics.py --vpn-type ipsec --host 10.0.2.10 --duration 30
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime


PUSHGATEWAY_URL = "http://localhost:9091"


def run_iperf_test(host: str, port: int = 5201, duration: int = 10) -> dict:
    """Run iperf3 test and return JSON results."""
    cmd = ["iperf3", "-c", host, "-p", str(port), "-t", str(duration), "-J"]
    
    print(f"Running: {' '.join(cmd)}")
    start_time = time.time()
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=duration + 30)
        elapsed = time.time() - start_time
        
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return {
                "success": True,
                "elapsed": elapsed,
                "data": data
            }
        else:
            return {
                "success": False,
                "elapsed": elapsed,
                "error": result.stderr
            }
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timeout"}
    except json.JSONDecodeError as e:
        return {"success": False, "error": f"JSON parse error: {e}"}
    except Exception as e:
        return {"success": False, "error": str(e)}


def parse_iperf_results(data: dict) -> dict:
    """Parse iperf3 JSON output and extract key metrics."""
    metrics = {}
    
    try:
        end = data.get("end", {})
        
        # Sender stats
        sum_sent = end.get("sum_sent", {})
        metrics["throughput_mbps"] = sum_sent.get("bits_per_second", 0) / 1_000_000
        metrics["bytes_sent"] = sum_sent.get("bytes", 0)
        metrics["retransmits"] = sum_sent.get("retransmits", 0)
        
        # Receiver stats
        sum_received = end.get("sum_received", {})
        metrics["throughput_recv_mbps"] = sum_received.get("bits_per_second", 0) / 1_000_000
        metrics["bytes_received"] = sum_received.get("bytes", 0)
        
        # Streams info
        streams = end.get("streams", [])
        if streams:
            # Calculate jitter from UDP tests if available
            for stream in streams:
                udp = stream.get("udp", {})
                if udp:
                    metrics["jitter_ms"] = udp.get("jitter_ms", 0)
                    metrics["lost_packets"] = udp.get("lost_packets", 0)
                    metrics["lost_percent"] = udp.get("lost_percent", 0)
        
        # CPU usage
        cpu = end.get("cpu_utilization_percent", {})
        metrics["cpu_host_total"] = cpu.get("host_total", 0)
        metrics["cpu_remote_total"] = cpu.get("remote_total", 0)
        
    except Exception as e:
        print(f"Warning: Error parsing iperf results: {e}")
    
    return metrics


def push_to_prometheus(metrics: dict, vpn_type: str, host: str, job: str = "iperf_test"):
    """Push metrics to Prometheus Pushgateway."""
    
    # Build metrics in Prometheus exposition format
    lines = []
    timestamp = int(time.time() * 1000)
    
    for metric_name, value in metrics.items():
        if isinstance(value, (int, float)):
            prom_name = f"vpn_iperf_{metric_name}"
            lines.append(f'{prom_name}{{vpn_type="{vpn_type}",target="{host}"}} {value}')
    
    # Add test metadata
    lines.append(f'vpn_iperf_test_timestamp{{vpn_type="{vpn_type}",target="{host}"}} {timestamp}')
    lines.append(f'vpn_iperf_test_success{{vpn_type="{vpn_type}",target="{host}"}} 1')
    
    payload = '\n'.join(lines) + '\n'
    
    # Push to Pushgateway
    url = f"{PUSHGATEWAY_URL}/metrics/job/{job}/vpn_type/{vpn_type}/target/{host.replace('.', '_')}"
    
    try:
        req = urllib.request.Request(
            url,
            data=payload.encode('utf-8'),
            method='POST'
        )
        req.add_header('Content-Type', 'text/plain')
        
        with urllib.request.urlopen(req, timeout=10) as response:
            if response.status == 200:
                print(f"✓ Metrics pushed to Pushgateway: {url}")
                return True
            else:
                print(f"✗ Pushgateway returned status {response.status}")
                return False
                
    except urllib.error.URLError as e:
        print(f"✗ Failed to push to Pushgateway: {e}")
        print(f"  Make sure Pushgateway is running at {PUSHGATEWAY_URL}")
        return False


def run_latency_test(host: str, count: int = 10) -> float:
    """Run ping test and return average latency in ms."""
    try:
        result = subprocess.run(
            ["ping", "-c", str(count), "-W", "2", host],
            capture_output=True, text=True, timeout=30
        )
        
        if result.returncode == 0:
            # Parse average from: rtt min/avg/max/mdev = 0.123/0.456/0.789/0.012 ms
            import re
            match = re.search(r'rtt [^=]+= [\d.]+/([\d.]+)/', result.stdout)
            if match:
                return float(match.group(1))
    except Exception:
        pass
    
    return -1


def main():
    parser = argparse.ArgumentParser(description="Run iperf3 test and push results to Prometheus")
    parser.add_argument("--vpn-type", required=True, choices=["wireguard", "ipsec", "direct"],
                        help="VPN type being tested")
    parser.add_argument("--host", required=True, help="Target host for iperf3 test")
    parser.add_argument("--port", type=int, default=5201, help="iperf3 port (default: 5201)")
    parser.add_argument("--duration", type=int, default=10, help="Test duration in seconds")
    parser.add_argument("--pushgateway", default=PUSHGATEWAY_URL, help="Pushgateway URL")
    parser.add_argument("--latency-test", action="store_true", help="Also run latency test")
    parser.add_argument("--no-push", action="store_true", help="Don't push to Prometheus (dry run)")
    
    args = parser.parse_args()
    
    global PUSHGATEWAY_URL
    PUSHGATEWAY_URL = args.pushgateway
    
    print(f"\n{'='*60}")
    print(f"VPN Performance Test - {args.vpn_type.upper()}")
    print(f"{'='*60}")
    print(f"Target: {args.host}:{args.port}")
    print(f"Duration: {args.duration}s")
    print(f"Timestamp: {datetime.now().isoformat()}")
    print(f"{'='*60}\n")
    
    # Run iperf test
    result = run_iperf_test(args.host, args.port, args.duration)
    
    if not result["success"]:
        print(f"\n✗ Test failed: {result.get('error', 'Unknown error')}")
        sys.exit(1)
    
    # Parse results
    metrics = parse_iperf_results(result["data"])
    
    # Add latency if requested
    if args.latency_test:
        print("\nRunning latency test...")
        latency = run_latency_test(args.host)
        if latency >= 0:
            metrics["latency_avg_ms"] = latency
            print(f"  Average latency: {latency:.2f} ms")
    
    # Print results
    print("\n" + "-"*40)
    print("Results:")
    print("-"*40)
    print(f"  Throughput (TX): {metrics.get('throughput_mbps', 0):.2f} Mbps")
    print(f"  Throughput (RX): {metrics.get('throughput_recv_mbps', 0):.2f} Mbps")
    print(f"  Bytes Sent:      {metrics.get('bytes_sent', 0):,}")
    print(f"  Bytes Received:  {metrics.get('bytes_received', 0):,}")
    print(f"  Retransmits:     {metrics.get('retransmits', 0)}")
    print(f"  CPU (local):     {metrics.get('cpu_host_total', 0):.1f}%")
    print(f"  CPU (remote):    {metrics.get('cpu_remote_total', 0):.1f}%")
    if "latency_avg_ms" in metrics:
        print(f"  Latency (avg):   {metrics['latency_avg_ms']:.2f} ms")
    print("-"*40 + "\n")
    
    # Push to Prometheus
    if not args.no_push:
        push_to_prometheus(metrics, args.vpn_type, args.host)
    else:
        print("(Dry run - metrics not pushed)")
    
    print("\n✓ Test complete!")


if __name__ == "__main__":
    main()
