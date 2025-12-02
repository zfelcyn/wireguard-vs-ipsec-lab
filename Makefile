SHELL:=/bin/bash
A:=automation
E:=experiments
T:=testbed

.PHONY: help
help:
	@echo "=== VPN Setup ==="
	@echo "make setup          - install Ansible roles (local)"
	@echo "make gen-keys       - generate WireGuard keys for both peers"
	@echo "make wg-up          - bring up WireGuard on both peers via Ansible"
	@echo "make wg-down        - tear down WireGuard"
	@echo ""
	@echo "=== Monitoring (Prometheus + Grafana) ==="
	@echo "make mon-up         - start Prometheus+Grafana monitoring stack"
	@echo "make mon-down       - stop monitoring stack"
	@echo "make mon-logs       - view monitoring stack logs"
	@echo "make mon-status     - show monitoring container status"
	@echo ""
	@echo "=== Performance Testing ==="
	@echo "make tools-up       - start iperf3 tools (docker)"
	@echo "make perf           - run baseline iperf matrix"
	@echo "make perf-wg        - run iperf test via WireGuard and push to Prometheus"
	@echo "make perf-ipsec     - run iperf test via IPsec and push to Prometheus"
	@echo ""
	@echo "=== URLs ==="
	@echo "  Grafana:      http://localhost:3000  (admin/vpnlab123)"
	@echo "  Prometheus:   http://localhost:9090"
	@echo "  Pushgateway:  http://localhost:9091"

setup:
	cd $(A)/ansible && ansible-galaxy install -r requirements.yaml || true

gen-keys:
	bash $(A)/scripts/gen-keys.sh

wg-up:
	ansible-playbook $(A)/ansible/playbooks/site-wireguard.yaml -i $(A)/ansible/inventories/hosts.yaml

wg-down:
	ansible-playbook $(A)/ansible/playbooks/site-wireguard.yaml -i $(A)/ansible/inventories/hosts.yaml -e state=absent

# ============================================
# Monitoring Stack
# ============================================
mon-up:
	docker compose -f $(T)/docker-compose.monitoring.yaml up -d
	@echo ""
	@echo "✓ Monitoring stack started!"
	@echo "  → Grafana:    http://localhost:3000  (admin/vpnlab123)"
	@echo "  → Prometheus: http://localhost:9090"
	@echo "  → Pushgateway: http://localhost:9091"

mon-down:
	docker compose -f $(T)/docker-compose.monitoring.yaml down

mon-logs:
	docker compose -f $(T)/docker-compose.monitoring.yaml logs -f

mon-status:
	docker compose -f $(T)/docker-compose.monitoring.yaml ps

# ============================================
# Performance Testing
# ============================================
tools-up:
	docker compose -f $(T)/docker-compose.tools.yaml up -d

perf:
	python3 $(E)/perf/run_iperf_matrix.py --inventory $(A)/ansible/inventories/hosts.yaml --out $(E)/perf/raw

# Run iperf test via WireGuard and push metrics to Prometheus
# Usage: make perf-wg HOST=10.10.10.2
perf-wg:
	python3 $(T)/monitoring/exporter/push_iperf_metrics.py \
		--vpn-type wireguard \
		--host $${HOST:-10.10.10.2} \
		--duration 30 \
		--latency-test

# Run iperf test via IPsec and push metrics to Prometheus
# Usage: make perf-ipsec HOST=10.0.2.10
perf-ipsec:
	python3 $(T)/monitoring/exporter/push_iperf_metrics.py \
		--vpn-type ipsec \
		--host $${HOST:-10.0.2.10} \
		--duration 30 \
		--latency-test

# Run comparison test (both VPNs)
perf-compare:
	@echo "Running WireGuard test..."
	python3 $(T)/monitoring/exporter/push_iperf_metrics.py \
		--vpn-type wireguard --host $${WG_HOST:-10.10.10.2} --duration 30 --latency-test
	@echo ""
	@echo "Running IPsec test..."
	python3 $(T)/monitoring/exporter/push_iperf_metrics.py \
		--vpn-type ipsec --host $${IPSEC_HOST:-10.0.2.10} --duration 30 --latency-test
	@echo ""
	@echo "✓ Both tests complete! View results in Grafana: http://localhost:3000"
