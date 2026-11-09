# damienzonly.stats

Omarchy shell bar widget in the spirit of Stats for macOS: CPU, RAM, GPU,
power and network sparklines in the bar, with a popup showing 5-minute graphs, per-core
load, memory breakdown, GPU load/memory (with a device picker on multi-GPU
machines), per-interface network traffic (click an interface to graph it),
power draw (with CPU/GPU breakdown and battery charge graphs), temperatures and
top processes by CPU, RAM, GPU and VRAM.

## Power

The bar shows the system draw in watts and the battery charge. How the draw
is measured, best source first:

1. On battery: the battery discharge rate, which is the whole system's draw.
2. RAPL `psys` (recent Intel laptops): platform power.
3. Otherwise (on AC), a lower bound marked `~`: battery charging power + CPU
   package (RAPL) + GPU power (hwmon `power1_*`, e.g. amdgpu PPT). The screen,
   SSD and the rest of the board aren't counted.

RAPL `energy_uj` is root-only by default (it was restricted because of the
PLATYPUS power side channel, CVE-2020-8694). To let the widget read it:

```
echo 'ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="/bin/chmod a+r /sys%p/energy_uj"' \
  | sudo tee /etc/udev/rules.d/99-rapl-read.rules
sudo udevadm trigger -s powercap -c add
```

## GPU support

| Vendor / driver | Load, memory | Per-process | Temperature |
|---|---|---|---|
| AMD `amdgpu` | sysfs | DRM fdinfo | hwmon |
| Intel `i915` / `xe` | DRM fdinfo | DRM fdinfo | hwmon (dGPU); iGPU shows CPU package |
| NVIDIA proprietary | `nvidia-smi` | `nvidia-smi pmon` | `nvidia-smi` |
| Other DRM drivers (nouveau, asahi, msm, panfrost…) | DRM fdinfo, if the driver exposes it | DRM fdinfo | hwmon |

fdinfo only covers processes the current user can inspect. Only AMD and Intel
have been tested.

## Files

- `sampler.py` — long-running; emits one JSON sample per interval
- `procs.py` — one-shot; top processes and IPv4 addresses (popup open only)
- `gpu.py` — GPU discovery, fdinfo and nvidia-smi helpers
- `Graph.qml` — canvas line/area graph

Requires `python3`; `lspci` (pciutils) is used for GPU names when present.

Settings (`shell.json`): `historySeconds` (default 300), `sampleInterval` (default 1).
Both can be changed from the popup's GRAPHS section (window 1m/5m/15m/1h,
interval 1s/2s/5s), which saves them via `omarchy bar set`. Long windows are
drawn at about one point per pixel, keeping each pixel's peak.

Toggle the popup from a keybinding: `omarchy-shell damienzonly.stats toggle`.
