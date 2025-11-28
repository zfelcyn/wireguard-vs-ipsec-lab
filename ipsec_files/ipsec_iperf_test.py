#!/usr/bin/env python3
import csv
import subprocess
import sys
import time
from pathlib import Path

# ----- CONFIG -----
# VM1: 192.168.56.101 
# VM2: 192.168.56.102, tunnel LAN address 10.2.0.1
targets = [
    # label      host             port
    ("direct",   "192.168.56.102", 5201),  # host-only, no IPsec
    ("ipsec",    "10.2.0.1",       5201),  # goes over IPsec tunnel
]

DURATION = 10  
def get_out_dir() -> Path:
    if "--out" in sys.argv:
        idx = sys.argv.index("--out")
        try:
            out = Path(sys.argv[idx + 1])
        except IndexError:
            print("ERROR: --out given but no path provided", file=sys.stderr)
            sys.exit(1)
    else:
        out = Path(".")
    out.mkdir(parents=True, exist_ok=True)
    return out

def run_iperf(label: str, host: str, port: int, duration: int):
    cmd = [
        "iperf3",
        "-c", host,
        "-p", str(port),
        "-t", str(duration),
        "-J",               
    ]
    print(f"\n[+] Running {label} test: {' '.join(cmd)}")
    start = time.time()
    try:
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
        )
        elapsed = time.time() - start
        return {
            "label": label,
            "host": host,
            "port": port,
            "elapsed_s": elapsed,
            "json_or_error": r.stdout.strip(),
        }
    except subprocess.CalledProcessError as e:
        elapsed = time.time() - start
        print(f"[!] {label} test failed: {e}", file=sys.stderr)
        return {
            "label": label,
            "host": host,
            "port": port,
            "elapsed_s": elapsed,
            "json_or_error": f"ERROR: {e.stderr.strip()}",
        }

def main():
    out_dir = get_out_dir()
    rows = []
    for label, host, port in targets:
        rows.append(run_iperf(label, host, port, DURATION))

    out_csv = out_dir / "iperf_ipsec_results.csv"
    with out_csv.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["label", "host", "port", "elapsed_s", "json_or_error"])
        for r in rows:
            writer.writerow([
                r["label"],
                r["host"],
                r["port"],
                f"{r['elapsed_s']:.3f}",
                r["json_or_error"],
            ])

    print(f"\n[+] Saved results to: {out_csv}")

if __name__ == "__main__":
    main()
