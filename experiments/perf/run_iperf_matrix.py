#!/usr/bin/env python3
import csv, subprocess, sys, time
targets = [
    ("direct", "peer_b_public_ip", 5201),
    ("tunnel", "10.0.2.10", 5201),  # sample host behind B (replace)
]
out = sys.argv[sys.argv.index("--out")+1] if "--out" in sys.argv else "."
rows=[]
for label, host, port in targets:
    cmd = ["iperf3","-c",host,"-p",str(port),"-t","10","-J"]
    print("Running:", " ".join(cmd))
    start=time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, check=True)
        rows.append([label, host, port, time.time()-start, r.stdout])
    except subprocess.CalledProcessError as e:
        rows.append([label, host, port, time.time()-start, f"ERROR: {e.stderr}"])
with open(f"{out}/iperf_results.csv","w",newline="") as f:
    csv.writer(f).writerows([["label","host","port","elapsed_s","json_or_error"]]+rows)
print("Saved:", f"{out}/iperf_results.csv")
