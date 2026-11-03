#!/usr/bin/env bash
# Prints one JSON object with the top processes by CPU (instantaneous, from a
# second top frame), by resident memory, by GPU engine time and by VRAM, plus
# IPv4 addresses per interface.
#
# GPU usage comes from DRM fdinfo (amdgpu): two snapshots taken around the top
# run give each client's engine-time delta; VRAM is the resident size. A DRM
# client is shared by every fd that dups it, so clients are deduplicated by
# drm-client-id.

count="${1:-5}"

gpu_snapshot() {
  find /proc/[0-9]*/fd -lname '/dev/dri/*' 2>/dev/null \
    | sed 's#/fd/#/fdinfo/#' \
    | xargs -r grep -H -E '^drm-(driver|client-id|engine-[a-z]+|resident-vram):' 2>/dev/null
}

gpu_t0=$(date +%s%N)
gpu_s0=$(gpu_snapshot)

cpu=$(top -b -n 2 -d 0.7 -o %CPU -w 512 | awk -v count="$count" '
  /^top -/ { frame++ }
  frame == 2 && header && shown < count {
    name = $12
    gsub(/["\\]/, "", name)
    out = out (out == "" ? "" : ",") "{\"pid\":" $1 ",\"name\":\"" name "\",\"cpu\":" $9 "}"
    shown++
  }
  frame == 2 && $1 == "PID" { header = 1 }
  END { print out }
')

gpu_s1=$(gpu_snapshot)
gpu_t1=$(date +%s%N)

gpu=$( { echo "@0"; echo "$gpu_s0"; echo "@1"; echo "$gpu_s1"; } | awk -v dt="$((gpu_t1 - gpu_t0))" -v count="$count" '
  function kib(v,   n, u) {
    n = v + 0
    if (v ~ /MiB/) return n * 1024
    if (v ~ /GiB/) return n * 1048576
    if (v ~ /KiB/) return n
    return n / 1024
  }
  /^@/ { snap = substr($0, 2); next }
  {
    # /proc/PID/fdinfo/FD:key:\tvalue
    split($0, parts, ":")
    split(parts[1], path, "/")
    pid = path[3]; fd = path[5]
    key = parts[2]; value = parts[3]
    gsub(/^[ \t]+/, "", value)
    id = snap SUBSEP pid SUBSEP fd
    if (key == "drm-driver") driver[id] = value
    else if (key == "drm-client-id") client[id] = value
    else if (key == "drm-resident-vram") vram[id] = kib(value)
    else if (key ~ /^drm-engine-/) engine[id] += value + 0
  }
  END {
    for (id in client) {
      if (driver[id] != "amdgpu") continue
      split(id, k, SUBSEP)
      ckey = k[1] SUBSEP k[2] SUBSEP client[id]
      if (ckey in seen) continue
      seen[ckey] = 1
      if (k[1] == "0") { eng0[k[2] SUBSEP client[id]] = engine[id]; continue }
      pids[k[2]] = 1
      pvram[k[2]] += vram[id]
      busy[k[2] SUBSEP client[id]] = engine[id]
    }
    for (bk in busy) {
      split(bk, b, SUBSEP)
      if (bk in eng0 && busy[bk] >= eng0[bk]) pgpu[b[1]] += (busy[bk] - eng0[bk]) / dt * 100
    }
    n = 0
    for (pid in pids) {
      name = ""
      if ((getline name < ("/proc/" pid "/comm")) <= 0) name = pid
      close("/proc/" pid "/comm")
      gsub(/["\\]/, "", name)
      g = pgpu[pid] + 0
      if (g > 100) g = 100
      rows[++n] = "{\"pid\":" pid ",\"name\":\"" name "\",\"gpu\":" sprintf("%.1f", g) ",\"vram\":" sprintf("%.0f", pvram[pid]) "}"
      gval[n] = g; vval[n] = pvram[pid]
    }
    # Two sorted top-N lists: by GPU time and by VRAM.
    for (pass = 0; pass < 2; pass++) {
      for (i = 1; i <= n; i++) used[i] = 0
      out = ""
      for (c = 0; c < count && c < n; c++) {
        best = 0
        for (i = 1; i <= n; i++) {
          if (used[i]) continue
          v = pass == 0 ? gval[i] : vval[i]
          if (!best || v > (pass == 0 ? gval[best] : vval[best])) best = i
        }
        used[best] = 1
        out = out (out == "" ? "" : ",") rows[best]
      }
      lists[pass] = out
    }
    printf "\"gpu\":[%s],\"vram\":[%s]", lists[0], lists[1]
  }
')

mem=$(ps -eo pid=,rss=,comm= --sort=-rss | head -n "$count" | awk '
  {
    name = $3
    gsub(/["\\]/, "", name)
    out = out (out == "" ? "" : ",") "{\"pid\":" $1 ",\"name\":\"" name "\",\"rss\":" $2 "}"
  }
  END { print out }
')

ips=$(ip -o -4 addr show 2>/dev/null | awk '
  { split($4, a, "/"); out = out (out == "" ? "" : ",") "\"" $2 "\":\"" a[1] "\"" }
  END { print out }
')

printf '{"cpu":[%s],"mem":[%s],%s,"ips":{%s}}\n' "$cpu" "$mem" "${gpu:-\"gpu\":[],\"vram\":[]}" "$ips"
