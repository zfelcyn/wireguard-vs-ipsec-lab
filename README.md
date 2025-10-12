---

# WireGuard vs IPsec – Site-to-Site VPN Study

This repository implements and benchmarks a **site-to-site VPN comparison** between **WireGuard** and **IPsec (Strongswan)**.
It provides a reproducible environment for deploying both VPN types, running performance tests, analyzing throughput and latency, and exploring basic security and observability metrics.

---

## Project Overview

| Aspect          | Description                                                                                   |
| --------------- | --------------------------------------------------------------------------------------------- |
| **Goal**        | Compare WireGuard and IPsec for secure site-to-site connectivity.                             |
| **Focus Areas** | Performance (throughput & latency), security configuration, and ease of deployment.           |
| **Structure**   | Two virtual sites (Network A and Network B) connected via a tunnel.                           |
| **Tools**       | Ansible for automation, iperf3 for benchmarking, Prometheus + Grafana for metrics (optional). |

---

## Repository Layout

```
docs/           →  proposal, setup notes, performance methodology, security checklist
envs/           →  per-network VPN configs (WireGuard & IPsec)
automation/     →  Ansible roles, playbooks, and scripts for repeatable setup
testbed/        →  optional Docker-based tooling (Grafana, Prometheus, iperf3)
experiments/    →  scripts, raw CSV logs, notebooks for analysis
tools/          →  helpers for packet capture and inspection
```

---

## Quick Start (Manual or Ansible)

### 1  Clone and enter

```bash
git clone https://github.com/<your-org>/wireguard-study.git
cd wireguard-study
```

### 2  Generate WireGuard keys (creates `envs/**/wireguard/keys/`)

```bash
make gen-keys
```

### 3  Configure peers

Edit `envs/network-a/wireguard/wg0.conf.sample` and `envs/network-b/wireguard/wg0.conf.sample`
→ fill `PrivateKey`, `PublicKey`, and `Endpoint` for each side, then save as `wg0.conf`.

Example:

```ini
[Interface]
Address = 10.10.10.1/24
PrivateKey = <BASE64_PRIVATE_KEY>
ListenPort = 51820

[Peer]
PublicKey = <PEER_PUBLIC_KEY>
AllowedIPs = 10.10.10.0/24, 10.0.2.0/24
Endpoint = <peer.public.ip>:51820
PersistentKeepalive = 25
```

### 4  Bring up the tunnel (natively)

```bash
sudo cp envs/network-a/wireguard/wg0.conf /etc/wireguard/wg0.conf
sudo wg-quick up wg0
sudo wg
```

Repeat on Network B.

### 5  Automate with Ansible (optional)

```bash
make wg-up        # deploy configs via Ansible
make wg-down      # remove configs
```

Edit `automation/ansible/inventories/hosts.yaml` with your actual IPs and CIDRs.

---

## Performance Testing

### Option 1  Hybrid (with Docker tools)

```bash
make tools-up     # start iperf3 containers
make perf         # run direct vs tunnel tests → CSV in experiments/perf/raw/
```

### Option 2  Native tools

Install `iperf3` locally on each peer:

```bash
iperf3 -s # on peer B
iperf3 -c <peerB IP> -t 10 -J # on peer A
```

---

## Observability (optional)

Start Prometheus + Grafana locally:

```bash
make mon-up
```

Visit `http://localhost:3000` to import dashboards and visualize VPN metrics.

---

## Experiments and Reports

| Folder                       | Purpose                                   |
| ---------------------------- | ----------------------------------------- |
| `experiments/perf/`          | iperf3 matrix runs and analysis notebooks |
| `experiments/security/`      | misconfiguration and sanity checks        |
| `experiments/nat-traversal/` | NAT testing notes                         |
| `docs/report/`               | final paper and slides                    |

---

## Automation Scripts

| Command                       | Action                           |
| ----------------------------- | -------------------------------- |
| `make setup`                  | install Ansible roles            |
| `make gen-keys`               | create WireGuard keypairs        |
| `make wg-up` / `make wg-down` | bring VPN up / down              |
| `make tools-up`               | launch iperf3 containers         |
| `make mon-up`                 | launch Prometheus + Grafana      |
| `make perf`                   | execute baseline performance run |

---

## Requirements

| Component  | Recommended Version            |
| ---------- | ------------------------------ |
| WireGuard  | ≥ 1.0 (kernel module or tools) |
| Strongswan | ≥ 5.9                          |
| Python     | ≥ 3.8                          |
| Ansible    | ≥ 2.15                         |
| Docker     | (optional) ≥ 24                |
| iperf3     | ≥ 3.10                         |

---

## Team & Acknowledgements

**Authors:** Zachary Felcyn, Simon Meili, Kyan Kotschevar-Smead
**Course:** CPTS 455, Washington State University
**Academic Term:** Fall 2025

---

