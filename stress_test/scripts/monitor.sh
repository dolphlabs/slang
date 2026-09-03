#!/bin/sh
# Samples RSS (KB), %CPU, and thread count for a PID once per second
# until it disappears or a stop file is created. Writes CSV.
#
# Usage: monitor.sh <pid> <out.csv> <stopfile>
set -u
pid="$1"
out="$2"
stopfile="$3"

echo "elapsed_s,rss_kb,cpu_pct,threads" > "$out"
start=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
    if [ -f "$stopfile" ]; then
        break
    fi
    now=$(date +%s)
    elapsed=$((now - start))
    line=$(ps -o rss=,%cpu= -p "$pid" 2>/dev/null)
    rss=$(echo "$line" | awk '{print $1}')
    cpu=$(echo "$line" | awk '{print $2}')
    th=$(($(ps -M -p "$pid" 2>/dev/null | wc -l) - 1))
    if [ -z "$rss" ]; then
        break
    fi
    echo "$elapsed,$rss,$cpu,$th" >> "$out"
    sleep 1
done
