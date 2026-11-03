# damienzonly.stats

Omarchy shell bar widget in the spirit of Stats for macOS: CPU, RAM, GPU and
network sparklines in the bar, with a popup showing 5-minute graphs, per-core
load, memory breakdown, GPU load/memory (with a device picker on multi-GPU
machines), per-interface network traffic (click an interface to graph it),
temperatures and top processes by CPU, RAM, GPU and VRAM.

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
