#!/usr/bin/env bash
# A/B harness for fix-gc.md: two slangc builds, ABBA order, medians + raw.
#
#   bench/gc/ab.sh <slangc-A> <slangc-B>
#
# Each slangc splices the runtime/ next to it, so A and B are usually two
# checkouts (e.g. a `git worktree` of dev beside the branch). Per variant
# and round it runs:
#   decode1  bench/gc/decode, 1 worker, 1 task   (USE=1: result walked)
#   decode4  bench/gc/decode, 4 workers, 4 tasks (same total decodes)
#   quote    bench/suite/api/slang's POST /api/quote under bench/latgen,
#            4 workers. No database: the pool dials lazily and quote never
#            queries.
# Env: ROUNDS (2), DECODES (400), CONNS (64), DUR (10s), WARM (2s),
#      PORT (18090), OUT (a fresh temp dir), STAGES ("decode1 decode4 quote"),
#      STAGE_TIMEOUT (seconds a decode run or a latgen run may take, 120).
#
# Every run is bounded: one that overruns STAGE_TIMEOUT is killed, the
# harness prints "TIMEOUT <variant> <stage>" with the log path, kills the
# server, and exits 3 -- a wedged build must fail the comparison, not
# hang it. A "progress:" line goes to stdout after every run, so a watcher
# sees a stall within one stage.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <slangc-A> <slangc-B>" >&2
    exit 2
fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
A=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
B=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
ROUNDS=${ROUNDS:-2}
DECODES=${DECODES:-400}
CONNS=${CONNS:-64}
DUR=${DUR:-10s}
WARM=${WARM:-2s}
PORT=${PORT:-18090}
STAGES=${STAGES:-"decode1 decode4 quote"}
STAGE_TIMEOUT=${STAGE_TIMEOUT:-120}
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/slang-gc-ab.XXXXXX")}
mkdir -p "$OUT"
RES="$OUT/runs.txt"
: > "$RES"

QUOTE="$OUT/data/quote_0.json"
if [ ! -f "$QUOTE" ]; then
    mkdir -p "$OUT/data"
    python3 "$ROOT/bench/suite/lib/gen_quote.py" "$OUT/data" 1 2000 >/dev/null
fi
LATGEN="$OUT/latgen"
go build -o "$LATGEN" "$ROOT/bench/latgen/main.go"

build() { # variant slangc
    local d="$OUT/$1"
    mkdir -p "$d/decode" "$d/api"
    cp "$ROOT/bench/gc/decode/main.sl" "$d/decode/main.sl"
    cp "$ROOT/bench/suite/api/slang/main.sl" "$d/api/main.sl"
    "$2" "$d/decode/main.sl" -o "$d/decode/bin" >/dev/null
    "$2" "$d/api/main.sl" -o "$d/api/bin" >/dev/null
}
build A "$A"
build B "$B"

# Run "$@" for at most STAGE_TIMEOUT seconds. On overrun: kill it, report,
# and stop the whole comparison (exit 3). $1 names the run for the report.
SERVER_PID=""
bounded() { # what log cmd...
    local what=$1 log=$2
    shift 2
    "$@" &
    local pid=$!
    local fired="$OUT/.timeout.$pid"
    ( sleep "$STAGE_TIMEOUT"; touch "$fired"; kill -9 $pid 2>/dev/null ) &
    local dog=$!
    local rc=0
    wait $pid || rc=$?
    kill $dog 2>/dev/null || true
    wait $dog 2>/dev/null || true
    if [ -e "$fired" ]; then
        echo "TIMEOUT $what after ${STAGE_TIMEOUT}s (log: $log)" >&2
        [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
        exit 3
    fi
    return $rc
}

# key=value pairs from SLANG_GC_STAT and /usr/bin/time -l, one line per run.
decode_run() { # variant stage workers tasks
    local v=$1 st=$2 w=$3 t=$4 log="$OUT/$1-$2.log"
    bounded "$v $st" "$log" sh -c 'exec "$@" > "$0" 2>&1' "$log" \
        env SLANG_WORKERS="$w" TASKS="$t" ITERS=$((DECODES / t)) USE=1 \
        SLANG_GC_STAT=1 QUOTE="$QUOTE" \
        /usr/bin/time -l "$OUT/$v/decode/bin" || {
        echo "FAILED $v $st (log: $log)" >&2
        exit 3
    }
    python3 - "$v" "$st" "$log" >> "$RES" <<'EOF'
import re, sys
v, st, log = sys.argv[1:4]
s = open(log).read()
kv = dict(re.findall(r'\b(\w+)=(\d+)\b', s))
def num(pat):
    m = re.search(pat, s)
    return m.group(1) if m else "0"
f = {
    "wall_ms": kv.get("wall_ms", "0"),
    "cpu_s": "%.3f" % (float(num(r'([\d.]+) user')) + float(num(r'([\d.]+) sys'))),
    "rss_mb": "%.1f" % (int(num(r'(\d+)\s+maximum resident')) / 1048576),
    "minors": kv.get("minor_collects", "0"),
    "majors": kv.get("collects", "0"),
    "promoted": kv.get("promoted", "0"),
    "minor_pause_ms": "%.1f" % (int(kv.get("minor_pause_ns_total", "0")) / 1e6),
    "major_pause_ms": "%.1f" % (int(kv.get("pause_ns_total", "0")) / 1e6),
}
print(v, st, " ".join("%s=%s" % i for i in f.items()))
EOF
}

cpu_s() { # pid -> cumulative cpu seconds
    ps -o time= -p "$1" | python3 -c '
import sys
t = sys.stdin.read().strip()
p = [float(x) for x in t.replace("-", ":").split(":")]
s = 0.0
for x in p: s = s * 60 + x
print(s)'
}

quote_run() { # variant
    local v=$1 log="$OUT/$1-quote.log"
    env PORT="$PORT" WORKERS=4 SLANG_WORKERS=4 \
        DATABASE_URL="postgres://bench@127.0.0.1:1/bench" \
        "$OUT/$v/api/bin" > "$OUT/$v-server.log" 2>&1 &
    local pid=$!
    SERVER_PID=$pid
    local i=0
    until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ $i -gt 100 ]; then echo "server $v did not start" >&2; kill -9 $pid; exit 1; fi
        sleep 0.1
    done
    bounded "$v quote warm-up" "$OUT/$v-server.log" \
        "$LATGEN" -addr "127.0.0.1:$PORT" -path /api/quote -body-file "$QUOTE" \
        -c "$CONNS" -d "$WARM" > /dev/null
    local c0
    c0=$(cpu_s $pid)
    ( peak=0; while kill -0 $pid 2>/dev/null; do
        r=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' '); r=${r:-0}
        [ "$r" -gt "$peak" ] && peak=$r && echo $peak > "$OUT/$v-peak"
        sleep 0.2; done ) &
    local sampler=$!
    bounded "$v quote" "$log" \
        "$LATGEN" -addr "127.0.0.1:$PORT" -path /api/quote -body-file "$QUOTE" \
        -c "$CONNS" -d "$DUR" > "$log"
    local c1
    c1=$(cpu_s $pid)
    kill -9 $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    SERVER_PID=""
    kill $sampler 2>/dev/null || true
    wait $sampler 2>/dev/null || true
    python3 - "$v" "$log" "$c0" "$c1" "$(cat "$OUT/$v-peak" 2>/dev/null || echo 0)" >> "$RES" <<'EOF'
import re, sys
v, log, c0, c1, peak = sys.argv[1:6]
s = open(log).read()
rps = float(re.search(r'rps=([\d.]+)', s).group(1))
pct = dict(re.findall(r'(p50|p99|p99\.9)=([\d.]+)', s))
cpu = float(c1) - float(c0)
n = int(re.search(r'requests=(\d+)', s).group(1))
print(v, "quote", "rps=%.0f p50_ms=%s p99_ms=%s p999_ms=%s cpu_us_per_req=%.0f rss_mb=%.1f" % (
    rps, pct.get("p50"), pct.get("p99"), pct.get("p99.9"),
    cpu / n * 1e6 if n else 0, int(peak) / 1024))
EOF
}

one() { # variant
    for st in $STAGES; do
        case $st in
            decode1) decode_run "$1" decode1 1 1 ;;
            decode4) decode_run "$1" decode4 4 4 ;;
            quote) quote_run "$1" ;;
        esac
    done
}

for r in $(seq 1 "$ROUNDS"); do
    for v in A B B A; do
        one "$v"
        echo "progress: round $r variant $v done ($(wc -l < "$RES" | tr -d ' ') runs)"
    done
done

python3 - "$RES" "$A" "$B" <<'EOF'
import sys, statistics
res, a, b = sys.argv[1:4]
runs = {}
for line in open(res):
    v, st, *kvs = line.split()
    d = dict(kv.split("=") for kv in kvs)
    runs.setdefault((st, v), []).append(d)
print("A =", a)
print("B =", b)
for st in sorted({k[0] for k in runs}):
    keys = list(runs[(st, "A")][0].keys())
    print("\n%s (medians; raw in brackets)" % st)
    for k in keys:
        row = []
        for v in ("A", "B"):
            xs = [float(d[k]) for d in runs[(st, v)]]
            row.append("%s %g %s" % (v, statistics.median(xs), [float(x) for x in xs]))
        print("  %-16s %s" % (k, "   ".join(row)))
EOF
echo
echo "raw runs: $RES"
