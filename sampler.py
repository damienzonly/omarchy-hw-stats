#!/usr/bin/env python3
"""Emit one JSON sample per interval for damienzonly.stats.

Raw /proc/stat counters, meminfo, per-interface byte counters, CPU/NVMe
temperatures, CPU frequency, power (battery, AC, RAPL, GPU) and one entry per
GPU. Deltas and history are computed by the widget, except GPU busy for
fdinfo-based drivers and RAPL watts, which need the previous counters and are
computed here.
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


def batteries():
    """System batteries (peripherals report scope=Device). Watts are signed:
    positive while charging, negative while discharging."""
    out = []
    for ps in sorted(glob.glob("/sys/class/power_supply/*")):
        if G.read(ps + "/type").strip() != "Battery" or G.read(ps + "/scope").strip() == "Device":
            continue
        status = G.read(ps + "/status").strip() or "Unknown"
        volts = G.read_int(ps + "/voltage_now") / 1e6
        watts = G.read_int(ps + "/power_now") / 1e6
        if not watts:
            watts = abs(G.read_int(ps + "/current_now")) / 1e6 * volts
        watts = abs(watts)
        if status == "Discharging":
            watts = -watts
        elif status != "Charging":
            watts = 0.0
        # energy_* is in µWh; charge_* in µAh needs the voltage.
        now = G.read_int(ps + "/energy_now") / 1e6
        full = G.read_int(ps + "/energy_full") / 1e6
        design = G.read_int(ps + "/energy_full_design") / 1e6
        if not full:
            vd = G.read_int(ps + "/voltage_min_design") / 1e6 or volts
            now = G.read_int(ps + "/charge_now") / 1e6 * vd
            full = G.read_int(ps + "/charge_full") / 1e6 * vd
            design = G.read_int(ps + "/charge_full_design") / 1e6 * vd
        out.append({"name": os.path.basename(ps), "status": status,
                    "capacity": G.read_int(ps + "/capacity"), "watts": round(watts, 2),
                    "energyNow": round(now, 2), "energyFull": round(full, 2),
                    "energyDesign": round(design, 2), "cycles": G.read_int(ps + "/cycle_count")})
    return out


def ac_online():
    for ps in glob.glob("/sys/class/power_supply/*"):
        if G.read(ps + "/type").strip() in ("Mains", "USB", "USB_C") and G.read_int(ps + "/online"):
            return True
    return False


def rapl_domains():
    """Top-level RAPL zones whose counter we can read: [(name, path, range)].
    energy_uj is root-only by default; unreadable zones are skipped."""
    out = []
    for z in sorted(glob.glob("/sys/class/powercap/intel-rapl:[0-9]*")):
        if os.path.basename(z).count(":") != 1 or not os.access(z + "/energy_uj", os.R_OK):
            continue
        out.append((G.read(z + "/name").strip(), z + "/energy_uj", G.read_int(z + "/max_energy_range_uj")))
    return out


def gpu_watts(hwmon):
    if not hwmon:
        return 0.0
    uw = G.read_int(hwmon + "/power1_average") or G.read_int(hwmon + "/power1_input")
    return round(uw / 1e6, 2)


def main():
    cpu_hw = hwmon_by_name("coretemp", "k10temp", "zenpower", "cpu_thermal")
    nvme_hw = hwmon_by_name("nvme")
    gpus = G.discover()
    needs_fdinfo = any(g["vendor"] != "amd" and g["driver"] != "nvidia" for g in gpus)
    has_nvidia = any(g["driver"] == "nvidia" for g in gpus)
    rapl = rapl_domains()
    prev_rapl = {}

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
                     "temp": temp_c(g["hwmon"]), "power": gpu_watts(g["hwmon"]), "source": "fdinfo"}
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

        # RAPL: package-N zones summed as "cpu", psys (whole platform) kept apart.
        rapl_w = {}
        for name, path, rng in rapl:
            uj = G.read_int(path, -1)
            if uj < 0:
                continue
            before = prev_rapl.get(path)
            if before and now_ns > before[1]:
                d = uj - before[0]
                if d < 0:
                    d += rng
                key = "cpu" if name.startswith("package") else name
                rapl_w[key] = rapl_w.get(key, 0) + d / ((now_ns - before[1]) / 1e3)
            prev_rapl[path] = (uj, now_ns)

        prev_clients = clients
        prev_t = now_ns

        sample = {
            "cpu": cpu_counters(),
            "mem": meminfo(),
            "net": netdev(),
            "temp": {"cpu": temp_c(cpu_hw), "nvme": temp_c(nvme_hw)},
            "freq": cpu_freq_mhz(),
            "gpus": out_gpus,
            "power": {"ac": ac_online(), "batteries": batteries(),
                      "rapl": {k: round(v, 2) for k, v in rapl_w.items()},
                      "raplReadable": bool(rapl)},
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
