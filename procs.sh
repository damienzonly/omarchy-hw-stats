#!/usr/bin/env bash
# Prints one JSON object with the top processes by CPU (instantaneous, from a
# second top frame) and by resident memory, plus IPv4 addresses per interface.

count="${1:-5}"

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

printf '{"cpu":[%s],"mem":[%s],"ips":{%s}}\n' "$cpu" "$mem" "$ips"
