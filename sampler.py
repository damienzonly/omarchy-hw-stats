#!/usr/bin/env python3
"""Emit one JSON sample per interval for damienzonly.stats.

Raw /proc/stat counters, meminfo, per-interface byte counters, CPU/NVMe
temperatures, CPU frequency and one entry per GPU. Deltas and history are
computed by the widget, except GPU busy for fdinfo-based drivers, which needs
the previous engine counters and is computed here.
"""

import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu as G  # noqa: E402

INTERVAL = max(0.5, float(sys.argv[1])) if len(sys.argv) > 1 else 1.0
FD_RESCAN_EVERY = 5  # samples between scans for new DRM clients

MEM_KEYS = {"MemTotal", "MemAvailable", "Cached", "Buffers", "SwapTotal", "SwapFree", "Shmem", "SReclaimable"}


def hwmon_by_name(*names):
    for h in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        if G.read(h + "/name").strip() in names:
            return h
    return ""


def temp_c(hwmon):
    return G.read_int(hwmon + "/temp1_input") // 1000 if hwmon else 0


def cpu_counters():
    rows = []
    for line in G.read("/proc/stat").splitlines():
        if not line.startswith("cpu"):
            break
        f = line.split()
        vals = [int(x) for x in f[1:9]]
        rows.append([sum(vals), vals[3] + vals[4]])
    return rows


def meminfo():
    out = {}
    for line in G.read("/proc/meminfo").splitlines():
        key, _, rest = line.partition(":")
        if key in MEM_KEYS:
            out[key] = int(rest.split()[0])
    return out


def netdev():
    out = {}
    for line in G.read("/proc/net/dev").splitlines()[2:]:
        name, _, rest = line.partition(":")
        f = rest.split()
        if len(f) >= 9:
            out[name.strip()] = [int(f[0]), int(f[8])]
    return out


def cpu_freq_mhz():
    total = n = 0
    for f in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
        v = G.read_int(f)
        if v:
            total += v
            n += 1
    return total // n // 1000 if n else 0


def main():
    cpu_hw = hwmon_by_name("coretemp", "k10temp", "zenpower", "cpu_thermal")
    nvme_hw = hwmon_by_name("nvme")
    gpus = G.discover()
    needs_fdinfo = any(g["vendor"] != "amd" and g["driver"] != "nvidia" for g in gpus)
    has_nvidia = any(g["driver"] == "nvidia" for g in gpus)

    fd_paths = []
    prev_clients = {}
    prev_t = 0
    tick = 0

    while True:
        started = time.monotonic()

        clients = {}
        if needs_fdinfo:
            if tick % FD_RESCAN_EVERY == 0:
                fd_paths = G.drm_fdinfo_paths()
            clients = G.read_clients(fd_paths)
        now_ns = time.monotonic_ns()
        nv = G.nvidia_query() if has_nvidia else {}

        out_gpus = []
        for g in gpus:
            entry = {"id": g["id"], "vendor": g["vendor"], "driver": g["driver"], "name": g["name"],
                     "busy": 0, "memUsed": 0, "memTotal": 0, "gttUsed": 0, "gttTotal": 0,
                     "temp": temp_c(g["hwmon"]), "source": "fdinfo"}
            dev = g["dev"]
            if g["driver"] == "amdgpu":
                entry.update(source="sysfs",
                             busy=G.read_int(dev + "/gpu_busy_percent"),
                             memUsed=G.read_int(dev + "/mem_info_vram_used"),
                             memTotal=G.read_int(dev + "/mem_info_vram_total"),
                             gttUsed=G.read_int(dev + "/mem_info_gtt_used"),
                             gttTotal=G.read_int(dev + "/mem_info_gtt_total"))
            elif g["driver"] == "nvidia":
                q = nv.get(G.bus_suffix(g["id"]))
                if q:
                    entry.update(source="nvidia-smi", busy=q["busy"], memUsed=q["memUsed"],
                                 memTotal=q["memTotal"], temp=q["temp"] or entry["temp"])
                else:
                    entry["source"] = "none"
            else:
                busy = vram = system = 0.0
                dt = now_ns - prev_t if prev_t else 0
                engine_busy = {}
                for key, c in clients.items():
                    if c["pdev"] != g["id"]:
                        continue
                    vram += c["vram"]
                    system += c["system"]
                    before = prev_clients.get(key)
                    if before and dt > 0:
                        # Sum clients per engine class, then take the busiest
                        # class: two clients on "render" add up, but render +
                        # video run in parallel.
                        for cls, ns in c["engines"].items():
                            p = before["engines"].get(cls)
                            if p is not None and ns >= p:
                                cap = c["capacity"].get(cls, 1)
                                engine_busy[cls] = engine_busy.get(cls, 0) + (ns - p) / dt / cap * 100
                        for cls, (cyc, total) in c["cycles"].items():
                            p = before["cycles"].get(cls)
                            if p and total > p[1] and cyc >= p[0]:
                                engine_busy["c:" + cls] = engine_busy.get("c:" + cls, 0) + (cyc - p[0]) / (total - p[1]) * 100
                busy = min(100.0, max(engine_busy.values(), default=0.0))
                entry.update(busy=round(busy, 1),
                             memUsed=int((vram or system) * 1024))
            out_gpus.append(entry)

        prev_clients = clients
        prev_t = now_ns

        sample = {
            "cpu": cpu_counters(),
            "mem": meminfo(),
            "net": netdev(),
            "temp": {"cpu": temp_c(cpu_hw), "nvme": temp_c(nvme_hw)},
            "freq": cpu_freq_mhz(),
            "gpus": out_gpus,
        }
        sys.stdout.write(json.dumps(sample, separators=(",", ":")) + "\n")
        sys.stdout.flush()

        tick += 1
        time.sleep(max(0.05, INTERVAL - (time.monotonic() - started)))


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
