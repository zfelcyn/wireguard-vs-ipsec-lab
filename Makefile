SHELL:=/bin/bash
A:=automation
E:=experiments
T:=testbed

.PHONY: help
help:
	@echo "make setup          - install Ansible roles (local)"
	@echo "make gen-keys       - generate WireGuard keys for both peers"
	@echo "make wg-up          - bring up WireGuard on both peers via Ansible"
	@echo "make wg-down        - tear down WireGuard"
	@echo "make mon-up         - start Prometheus+Grafana locally (docker)"
	@echo "make tools-up       - start iperf3 tools (docker)"
	@echo "make perf           - run baseline iperf matrix (locally triggers remote iperf)"

setup:
	cd $(A)/ansible && ansible-galaxy install -r requirements.yaml || true

gen-keys:
	bash $(A)/scripts/gen-keys.sh

wg-up:
	ansible-playbook $(A)/ansible/playbooks/site-wireguard.yaml -i $(A)/ansible/inventories/hosts.yaml

wg-down:
	ansible-playbook $(A)/ansible/playbooks/site-wireguard.yaml -i $(A)/ansible/inventories/hosts.yaml -e state=absent

mon-up:
	docker compose -f $(T)/docker-compose.observability.yaml up -d

tools-up:
	docker compose -f $(T)/docker-compose.tools.yaml up -d

perf:
	python3 $(E)/perf/run_iperf_matrix.py --inventory $(A)/ansible/inventories/hosts.yaml --out $(E)/perf/raw
