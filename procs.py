#!/usr/bin/env python3
"""Print one JSON object with the top processes and interface addresses.

CPU is measured over a short window from /proc/<pid>/stat, RAM is resident
set size, GPU/VRAM come from DRM fdinfo (or nvidia-smi pmon on the NVIDIA
proprietary driver). GPU entries carry the device id so the widget can
filter them by the selected GPU.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu as G  # noqa: E402

COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 5
WINDOW = 0.7
CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_KIB = os.sysconf("SC_PAGE_SIZE") // 1024


def comm(pid):
    return G.read("/proc/%s/comm" % pid).strip() or str(pid)


def cpu_ticks():
    ticks = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        stat = G.read("/proc/%s/stat" % pid)
        # Fields after the parenthesised command name; utime/stime are 14/15.
        rest = stat.rpartition(")")[2].split()
        if len(rest) > 12:
            ticks[pid] = int(rest[11]) + int(rest[12])
    return ticks


def top_rss():
    rows = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        statm = G.read("/proc/%s/statm" % pid).split()
        if len(statm) > 1:
            rows.append((int(statm[1]) * PAGE_KIB, pid))
    rows.sort(reverse=True)
    return [{"pid": int(pid), "name": comm(pid), "rss": rss} for rss, pid in rows[:COUNT]]


def ipv4():
    try:
        out = subprocess.run(["ip", "-o", "-4", "addr", "show"], capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    ips = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) > 3:
            ips.setdefault(f[1], f[3].split("/")[0])
    return ips


def main():
    gpus = G.discover()
    fdinfo_ids = {g["id"] for g in gpus if g["driver"] != "nvidia"}
    nvidia = {G.bus_suffix(g["id"]): g["id"] for g in gpus if g["driver"] == "nvidia"}

    paths = G.drm_fdinfo_paths() if fdinfo_ids else []
    t0 = time.monotonic_ns()
    ticks0 = cpu_ticks()
    clients0 = G.read_clients(paths)
    time.sleep(WINDOW)
    clients1 = G.read_clients(paths)
    ticks1 = cpu_ticks()
    dt_ns = time.monotonic_ns() - t0

    cpu = []
    for pid, t in ticks1.items():
        if pid in ticks0 and t >= ticks0[pid]:
            cpu.append(((t - ticks0[pid]) / CLK_TCK / (dt_ns / 1e9) * 100, pid))
    cpu.sort(reverse=True)
    top_cpu = [{"pid": int(pid), "name": comm(pid), "cpu": round(pct, 1)} for pct, pid in cpu[:COUNT]]

    # Per (gpu, pid): busy % and memory in KiB.
    usage = {}
    for key, c in clients1.items():
        if c["pdev"] not in fdinfo_ids:
            continue
        u = usage.setdefault((c["pdev"], c["pid"]), {"gpu": 0.0, "mem": 0.0})
        before = clients0.get(key)
        if before:
            u["gpu"] = min(100.0, u["gpu"] + G.client_busy(before, c, dt_ns))
        u["mem"] += c["vram"] or c["system"]
    for suffix, pid, sm, fb in G.nvidia_processes():
        dev = nvidia.get(suffix)
        if dev:
            u = usage.setdefault((dev, pid), {"gpu": 0.0, "mem": 0.0})
            u["gpu"] = min(100.0, u["gpu"] + sm)
            u["mem"] += fb / 1024

    gpu_rows = [{"gpu": dev, "pid": int(pid), "name": comm(pid), "busy": round(u["gpu"], 1),
                 "vram": round(u["mem"])} for (dev, pid), u in usage.items()]
    # Top N per GPU device, so each device's list is complete after filtering.
    by_gpu, by_vram = [], []
    for dev in {r["gpu"] for r in gpu_rows}:
        rows = [r for r in gpu_rows if r["gpu"] == dev]
        by_gpu += sorted(rows, key=lambda r: -r["busy"])[:COUNT]
        by_vram += sorted(rows, key=lambda r: -r["vram"])[:COUNT]

    print(json.dumps({"cpu": top_cpu, "mem": top_rss(), "gpu": by_gpu, "vram": by_vram, "ips": ipv4()},
                     separators=(",", ":")))


if __name__ == "__main__":
    main()
