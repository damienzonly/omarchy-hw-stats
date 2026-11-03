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

  awk -v ct="$(read_temp "$cpu_hw")" -v gt="$(read_temp "$gpu_hw")" -v nt="$(read_temp "$nvme_hw")" -v freq="$freq" '
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
      printf "{\"cpu\":[%s],\"mem\":{%s},\"net\":{%s},\"temp\":{\"cpu\":%d,\"gpu\":%d,\"nvme\":%d},\"freq\":%d}\n", \
        cpu, mem, net, ct / 1000, gt / 1000, nt / 1000, freq / 1000
      fflush()
    }
  ' /proc/stat /proc/meminfo /proc/net/dev

  sleep "$interval"
done
