#!/usr/bin/env bash
# Emits one JSON sample per interval for damienzonly.stats: raw /proc/stat
# counters, meminfo, per-interface byte counters, temperatures and CPU
# frequency. Deltas and history are computed by the widget.

interval="${1:-1}"

find_hwmon() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$h/name" 2>/dev/null)" == "$1" ]] && { echo "$h"; return; }
  done
}

cpu_hw=$(find_hwmon coretemp)
[[ -z "$cpu_hw" ]] && cpu_hw=$(find_hwmon k10temp)
gpu_hw=$(find_hwmon amdgpu)
nvme_hw=$(find_hwmon nvme)

# First DRM card exposing a load counter (amdgpu); card numbering changes
# between boots, so it's looked up by capability rather than index.
gpu_dev=""
for c in /sys/class/drm/card[0-9]*; do
  [[ -r "$c/device/gpu_busy_percent" ]] && { gpu_dev="$c/device"; break; }
done

read_num() {
  local v=0
  [[ -n "$1" && -r "$1" ]] && read -r v < "$1" 2>/dev/null
  echo "${v:-0}"
}

read_temp() {
  local v=0
  [[ -n "$1" && -r "$1/temp1_input" ]] && read -r v < "$1/temp1_input"
  echo "${v:-0}"
}

while :; do
  freq=0
  n=0
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [[ -r "$f" ]] || continue
    read -r v < "$f"
    freq=$((freq + v))
    n=$((n + 1))
  done
  (( n > 0 )) && freq=$((freq / n))

  awk -v ct="$(read_temp "$cpu_hw")" -v gt="$(read_temp "$gpu_hw")" -v nt="$(read_temp "$nvme_hw")" -v freq="$freq" \
      -v gbusy="$(read_num "${gpu_dev:+$gpu_dev/gpu_busy_percent}")" \
      -v vused="$(read_num "${gpu_dev:+$gpu_dev/mem_info_vram_used}")" \
      -v vtotal="$(read_num "${gpu_dev:+$gpu_dev/mem_info_vram_total}")" \
      -v gused="$(read_num "${gpu_dev:+$gpu_dev/mem_info_gtt_used}")" \
      -v gtotal="$(read_num "${gpu_dev:+$gpu_dev/mem_info_gtt_total}")" '
    FILENAME == "/proc/stat" && /^cpu/ {
      total = 0
      for (i = 2; i <= 9; i++) total += $i
      cpu = cpu (cpu == "" ? "" : ",") "[" total "," ($5 + $6) "]"
    }
    FILENAME == "/proc/meminfo" {
      key = $1; sub(":", "", key)
      if (key ~ /^(MemTotal|MemAvailable|Cached|Buffers|SwapTotal|SwapFree|Shmem|SReclaimable)$/)
        mem = mem (mem == "" ? "" : ",") "\"" key "\":" $2
    }
    FILENAME == "/proc/net/dev" && FNR > 2 {
      line = $0
      sub(/^ +/, "", line)
      split(line, parts, ":")
      split(parts[2], f, " ")
      net = net (net == "" ? "" : ",") "\"" parts[1] "\":[" f[1] "," f[9] "]"
    }
    END {
      printf "{\"cpu\":[%s],\"mem\":{%s},\"net\":{%s},\"temp\":{\"cpu\":%d,\"gpu\":%d,\"nvme\":%d},\"freq\":%d,", \
        cpu, mem, net, ct / 1000, gt / 1000, nt / 1000, freq / 1000
      printf "\"gpu\":{\"busy\":%d,\"vramUsed\":%.0f,\"vramTotal\":%.0f,\"gttUsed\":%.0f,\"gttTotal\":%.0f}}\n", \
        gbusy, vused, vtotal, gused, gtotal
      fflush()
    }
  ' /proc/stat /proc/meminfo /proc/net/dev

  sleep "$interval"
done
