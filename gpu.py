"""GPU discovery and sampling shared by sampler.py and procs.py.

Sources, per vendor:
  - amdgpu:  sysfs gpu_busy_percent / mem_info_* (device totals)
  - nvidia:  nvidia-smi (proprietary driver has no DRM fdinfo stats)
  - others:  DRM fdinfo (i915, xe, nouveau, msm, panfrost, asahi, ...): busy
             is derived from per-client engine time; memory from resident
             region sizes.
Per-process usage always comes from fdinfo, except NVIDIA (nvidia-smi pmon).
"""

import glob
import os
import re
import shutil
import subprocess

VENDORS = {
    "amdgpu": "amd", "radeon": "amd",
    "i915": "intel", "xe": "intel",
    "nvidia": "nvidia", "nouveau": "nvidia",
    "asahi": "apple",
}


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def read_int(path, default=0):
    try:
        return int(read(path).strip())
    except ValueError:
        return default


def lspci_name(pdev):
    if not shutil.which("lspci"):
        return ""
    try:
        out = subprocess.run(["lspci", "-s", pdev, "-mm"], capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    fields = re.findall(r'"([^"]*)"', out)
    if len(fields) < 3:
        return ""
    vendor = fields[1].split(",")[0].replace(" Corporation", "").replace("Advanced Micro Devices", "AMD").strip()
    vendor = re.sub(r"\s*\[.*?\]", "", vendor)
    device = fields[2]
    bracket = re.search(r"\[(.*?)\]", device)
    if bracket:
        device = bracket.group(1)
    return (vendor + " " + device).strip()


def discover():
    """List DRM cards: [{id, card, driver, vendor, name, dev, hwmon}]."""
    gpus = []
    for card in sorted(glob.glob("/sys/class/drm/card*")):
        base = os.path.basename(card)
        if not re.fullmatch(r"card\d+", base):
            continue
        dev = os.path.realpath(os.path.join(card, "device"))
        driver_link = os.path.join(dev, "driver")
        if not os.path.exists(driver_link):
            continue
        driver = os.path.basename(os.path.realpath(driver_link))
        pdev = os.path.basename(dev)
        hwmons = sorted(glob.glob(os.path.join(dev, "hwmon", "hwmon*")))
        gpus.append({
            "id": pdev,
            "card": base,
            "driver": driver,
            "vendor": VENDORS.get(driver, driver),
            "name": lspci_name(pdev) or driver,
            "dev": dev,
            "hwmon": hwmons[0] if hwmons else "",
        })
    return gpus


# ------------------------------------------------------------------ fdinfo

def drm_fdinfo_paths():
    """fdinfo paths of every open DRM fd we can see (our own processes)."""
    paths = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        fd_dir = "/proc/%s/fd" % pid
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(os.path.join(fd_dir, fd))
            except OSError:
                continue
            if target.startswith("/dev/dri/"):
                paths.append((pid, "/proc/%s/fdinfo/%s" % (pid, fd)))
    return paths


def _size_kib(value):
    parts = value.split()
    if not parts:
        return 0
    try:
        n = float(parts[0])
    except ValueError:
        return 0
    unit = parts[1] if len(parts) > 1 else ""
    if unit == "KiB":
        return n
    if unit == "MiB":
        return n * 1024
    if unit == "GiB":
        return n * 1048576
    return n / 1024


def read_clients(paths):
    """Parse fdinfo into DRM clients keyed by (pdev, client-id).

    Each client: {pid, pdev, driver, engines: {class: ns}, cycles: {class:
    (cycles, total)}, capacity: {class: n}, vram: KiB, system: KiB}.
    Several fds can share one client, so the first fd seen wins.
    """
    clients = {}
    for pid, path in paths:
        text = read(path)
        if "drm-client-id" not in text:
            continue
        info = {}
        for line in text.splitlines():
            key, sep, value = line.partition(":")
            if sep and key.startswith("drm-"):
                info[key] = value.strip()
        key = (info.get("drm-pdev", ""), info.get("drm-client-id", ""))
        if key in clients:
            continue
        c = {"pid": pid, "pdev": key[0], "driver": info.get("drm-driver", ""),
             "engines": {}, "cycles": {}, "capacity": {}, "vram": 0.0, "system": 0.0}
        for k, v in info.items():
            if k.startswith("drm-engine-capacity-"):
                c["capacity"][k[len("drm-engine-capacity-"):]] = max(1, int(v.split()[0] or 1))
            elif k.startswith("drm-engine-"):
                try:
                    c["engines"][k[len("drm-engine-"):]] = int(v.split()[0])
                except (ValueError, IndexError):
                    pass
            elif k.startswith("drm-total-cycles-"):
                cls = k[len("drm-total-cycles-"):]
                cyc = c["cycles"].get(cls, (0, 0))
                c["cycles"][cls] = (cyc[0], int(v.split()[0]))
            elif k.startswith("drm-cycles-"):
                cls = k[len("drm-cycles-"):]
                cyc = c["cycles"].get(cls, (0, 0))
                c["cycles"][cls] = (int(v.split()[0]), cyc[1])
            elif k.startswith("drm-resident-vram"):
                c["vram"] += _size_kib(v)
            elif k.startswith("drm-resident-system") or k.startswith("drm-resident-gtt"):
                c["system"] += _size_kib(v)
        clients[key] = c
    return clients


def client_busy(before, after, dt_ns):
    """Busy % of one client between two snapshots: the busiest engine class."""
    best = 0.0
    for cls, ns in after["engines"].items():
        prev = before["engines"].get(cls)
        if prev is None or ns < prev:
            continue
        cap = after["capacity"].get(cls, 1)
        best = max(best, (ns - prev) / dt_ns / cap * 100)
    for cls, (cyc, total) in after["cycles"].items():
        prev = before["cycles"].get(cls)
        if not prev or total <= prev[1] or cyc < prev[0]:
            continue
        best = max(best, (cyc - prev[0]) / (total - prev[1]) * 100)
    return min(100.0, best)


# ------------------------------------------------------------------ nvidia

def nvidia_query():
    """{pdev-suffix: {busy, memUsed, memTotal, temp}} from nvidia-smi."""
    if not shutil.which("nvidia-smi"):
        return {}
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=pci.bus_id,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    result = {}
    for line in out.splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) < 5:
            continue

        def num(x):
            try:
                return float(x)
            except ValueError:
                return 0.0
        result[bus_suffix(f[0])] = {
            "busy": num(f[1]),
            "memUsed": num(f[2]) * 1048576,
            "memTotal": num(f[3]) * 1048576,
            "temp": num(f[4]),
        }
    return result


def nvidia_index_map():
    """{gpu index: pdev-suffix} for mapping nvidia-smi pmon rows."""
    if not shutil.which("nvidia-smi"):
        return {}
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=index,pci.bus_id", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    result = {}
    for line in out.splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) == 2:
            result[f[0]] = bus_suffix(f[1])
    return result


def nvidia_processes():
    """[(pdev-suffix, pid, sm %, fb bytes)] from nvidia-smi pmon."""
    if not shutil.which("nvidia-smi"):
        return []
    index_map = nvidia_index_map()
    try:
        out = subprocess.run(["nvidia-smi", "pmon", "-c", "1", "-s", "um"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    header = []
    rows = []
    for line in out.splitlines():
        if line.startswith("#"):
            if not header:
                header = line.lstrip("#").split()
            continue
        f = line.split()
        if not header or len(f) < len(header) - 1:
            continue
        row = dict(zip(header, f))

        def num(k):
            try:
                return float(row.get(k, "0"))
            except ValueError:
                return 0.0
        pid = row.get("pid", "-")
        if not pid.isdigit():
            continue
        rows.append((index_map.get(row.get("gpu", ""), ""), pid, num("sm"), num("fb") * 1048576))
    return rows


def bus_suffix(bus_id):
    """'00000000:01:00.0' / '0000:01:00.0' -> '01:00.0' (domain-agnostic)."""
    return bus_id.lower().split(":", 1)[1] if bus_id.count(":") >= 2 else bus_id.lower()
