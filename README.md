# damienzonly.stats

Omarchy shell bar widget in the spirit of Stats for macOS: CPU, RAM and network
sparklines in the bar, with a popup showing 5-minute graphs, per-core load,
memory breakdown, per-interface network traffic (click an interface to graph
it), temperatures and top processes.

- `sampler.sh` — emits one JSON sample per interval from `/proc` and hwmon
- `procs.sh` — top processes by CPU/RAM and IPv4 addresses (popup only)
- `Graph.qml` — canvas line/area graph

Settings (`shell.json`): `historySeconds` (default 300), `sampleInterval` (default 1).

Toggle the popup from a keybinding: `omarchy-shell damienzonly.stats toggle`.
