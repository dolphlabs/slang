#!/bin/sh
# Real-server HTTP remeasure: slang stdlib/http / Go net/http, keep-alive.
# This is the axis bench/http/README.md flagged as having no numbers yet:
# actual HTTP/1.1 parsing on both sides, connections reused across many
# requests, not the raw-bytes ruler (run_http.sh) or the no-parser raw
# axis (run_http_opt.sh). Axum/Java/C# are not wired in here -- Go only,
# on purpose (see bench/http/README.md's axis table for where they'd go).
# Usage: HTTP_ROUNDS=3 HTTP_DUR=10s ./bench/run_http_realserver.sh

set -eu
cd "$(dirname "$0")/.."

ROUNDS="${HTTP_ROUNDS:-3}"
DUR="${HTTP_DUR:-10s}"
CONCS="${HTTP_CONCS:-50 200}"
SL_PORT="${HTTP_SL_RS_PORT:-18201}"
GO_PORT="${HTTP_GO_RS_PORT:-18202}"
OUT_DIR=/tmp/slang_http_realserver
mkdir -p "$OUT_DIR"
: >"$OUT_DIR/runs.tsv"
: >"$OUT_DIR/skipped.txt"

SL_BIN=/tmp/sl_bench_http_realserver
GO_BIN=/tmp/go_bench_http_realserver
LG_BIN=/tmp/http_loadgen

export HTTP_ACCEPTORS="${HTTP_ACCEPTORS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}"

if [ ! -x ./slangc ]; then
    make slangc
fi

skip() {
    echo "skip $1: $2" | tee -a "$OUT_DIR/skipped.txt"
}

kill_bin() {
    pkill -9 -f "$1" 2>/dev/null || true
}

kill_port() {
    p=$1
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    fi
}

HAVE_SL=0
HAVE_GO=0

cleanup() {
    [ "$HAVE_SL" -eq 1 ] && kill_bin "$SL_BIN"
    [ "$HAVE_GO" -eq 1 ] && kill_bin "$GO_BIN"
    kill_port "$SL_PORT"
    kill_port "$GO_PORT"
    # SO_REUSEPORT means a killed-but-not-yet-reaped listener from a
    # PRIOR run keeps taking a share of new connections silently
    # (measured, not theoretical -- see the PR this script shipped
    # with). Wait for the port to actually clear, not just for the
    # signal to have been sent.
    i=0
    while [ "$i" -lt 20 ] && { lsof -i ":${SL_PORT}" >/dev/null 2>&1 || lsof -i ":${GO_PORT}" >/dev/null 2>&1; }; do
        sleep 0.1
        i=$((i + 1))
    done
}
trap cleanup EXIT INT TERM
cleanup

time_sec() {
    tf="$OUT_DIR/time.$$"
    if ! /usr/bin/time -f '%e' -o "$tf" "$@" >/dev/null; then
        rm -f "$tf"
        return 1
    fi
    tail -n 1 "$tf"
    rm -f "$tf"
}

echo "=== compile (real-server axis) ==="
if c_sl=$(time_sec ./slangc bench/http/realserver/main.sl -o "$SL_BIN"); then
    HAVE_SL=1
else
    skip slang_realserver "slangc failed"
    c_sl="fail"
fi
if command -v go >/dev/null 2>&1 && c_go=$(time_sec go build -o "$GO_BIN" bench/http/main.go); then
    HAVE_GO=1
else
    skip go_realserver "go missing or build failed"
    c_go="fail"
fi
if command -v go >/dev/null 2>&1; then
    go build -o "$LG_BIN" bench/http/loadgen.go
fi

printf 'compile_s slang_realserver=%s go_net_http=%s\n' "$c_sl" "$c_go"
echo "$c_sl $c_go" >"$OUT_DIR/compile.txt"
echo "HTTP_ACCEPTORS=$HTTP_ACCEPTORS"

if [ ! -x "$LG_BIN" ]; then
    echo "loadgen (bench/http/loadgen.go) is required for this axis -- wrk doesn't do keep-alive HTTP/1.1 the way this needs, and Go is required to build it."
    exit 1
fi

LANGS=""
[ "$HAVE_SL" -eq 1 ] && LANGS="$LANGS slang_realserver"
[ "$HAVE_GO" -eq 1 ] && LANGS="$LANGS go_realserver"
LANGS=$(echo "$LANGS" | sed 's/^ *//')

rss_kb() {
    pid=$1
    if [ -r "/proc/$pid/status" ]; then
        v=$(awk '/^VmHWM:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)
        if [ -n "$v" ]; then
            echo "$v"
            return
        fi
    fi
    ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?"
}

wait_http() {
    port=$1
    i=0
    while [ "$i" -lt 80 ]; do
        if curl -sS -o /tmp/http_probe.body --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    return 1
}

run_load() {
    port=$1
    conc=$2
    out=$3
    url="http://127.0.0.1:${port}/"
    "$LG_BIN" -url "$url" -c "$conc" -d "$DUR" -keepalive >"$out" 2>&1 || true
    rps=$(sed -n 's/.*rps=\([0-9.]*\).*/\1/p' "$out")
    p50=$(sed -n 's/.*p50_ms=\([0-9.]*\).*/\1/p' "$out")
    p99=$(sed -n 's/.*p99_ms=\([0-9.]*\).*/\1/p' "$out")
    err=$(sed -n 's/.*errors=\([0-9]*\).*/\1/p' "$out")
    printf '%s %s %s %s' "${rps:-0}" "${p50:-0}" "${p99:-0}" "${err:-0}"
}

start_named() {
    name=$1
    case $name in
        slang_realserver)
            kill_port "$SL_PORT"
            HTTP_PORT="$SL_PORT" "$SL_BIN" >"$OUT_DIR/slang_realserver.log" 2>&1 &
            echo $!
            ;;
        go_realserver)
            kill_port "$GO_PORT"
            HTTP_PORT="$GO_PORT" "$GO_BIN" >"$OUT_DIR/go_realserver.log" 2>&1 &
            echo $!
            ;;
    esac
}

port_for() {
    name=$1
    case $name in
        slang_realserver) echo "$SL_PORT" ;;
        go_realserver) echo "$GO_PORT" ;;
    esac
}

run_server() {
    name=$1
    conc=$2
    round=$3
    pid=$(start_named "$name")
    port=$(port_for "$name")
    if ! wait_http "$port"; then
        echo "$name conc=$conc FAIL not ready (port=${port:-?})"
        if [ -f "$OUT_DIR/${name}.log" ]; then
            tail -n 20 "$OUT_DIR/${name}.log" || true
        fi
        printf '%s\t%s\t%s\t0\t0\t0\t1\t?\n' "$name" "$round" "$conc" >>"$OUT_DIR/runs.tsv"
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return
    fi
    blen=$(wc -c < /tmp/http_probe.body | tr -d ' ')
    load_out="$OUT_DIR/${name}_r${round}_c${conc}.log"
    set -- $(run_load "$port" "$conc" "$load_out")
    rps=$1; p50=$2; p99=$3; err=$4
    rss=$(rss_kb "$pid")
    printf '%s conc=%s rps=%s p50_ms=%s p99_ms=%s errors=%s rss_kb=%s body=%s\n' \
        "$name" "$conc" "$rps" "$p50" "$p99" "$err" "$rss" "$blen"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$round" "$conc" "$rps" "$p50" "$p99" "$err" "$rss" >>"$OUT_DIR/runs.tsv"
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ] && lsof -i ":${port}" >/dev/null 2>&1; do
        sleep 0.1
        i=$((i + 1))
    done
}

rotate_langs() {
    r=$1
    set -- $LANGS
    n=$#
    if [ "$n" -eq 0 ]; then
        return
    fi
    shift_n=$(( (r - 1) % n ))
    i=0
    while [ "$i" -lt "$shift_n" ]; do
        first=$1
        shift
        set -- "$@" "$first"
        i=$((i + 1))
    done
    if [ $((r % 2)) -eq 0 ]; then
        rev=""
        for x in "$@"; do
            rev="$x $rev"
        done
        echo "$rev"
    else
        echo "$@"
    fi
}

echo "http realserver bench duration=$DUR concs=$CONCS rounds=$ROUNDS"
echo "langs=$LANGS"
echo "loadgen=$LG_BIN -keepalive"
echo "axis=real-server (parse + route + headers, keep-alive)"

r=1
while [ "$r" -le "$ROUNDS" ]; do
    echo "-- round $r --"
    for name in $(rotate_langs "$r"); do
        for conc in $CONCS; do
            run_server "$name" "$conc" "$r"
        done
    done
    r=$((r + 1))
done

echo "-- medians --"
awk -F '\t' '
function med(a, n,    s, i, j, t) {
    for (i = 1; i <= n; i++) s[i] = a[i]
    for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
            if (s[j] + 0 < s[i] + 0) { t = s[i]; s[i] = s[j]; s[j] = t }
    if (n < 1) return 0
    if (n % 2) return s[int(n / 2) + 1]
    return (s[n / 2] + s[n / 2 + 1]) / 2
}
{
    key = $1 " c=" $3
    n[key]++
    rps[key, n[key]] = $4
    p50[key, n[key]] = $5
    p99[key, n[key]] = $6
    err[key, n[key]] = $7
    rss[key, n[key]] = $8
}
END {
    for (k in n) {
        nw = n[k]
        split("", a1); split("", a2); split("", a3); split("", a4); split("", a5)
        for (i = 1; i <= nw; i++) {
            a1[i] = rps[k, i]; a2[i] = p50[k, i]; a3[i] = p99[k, i]
            a4[i] = err[k, i]; a5[i] = rss[k, i]
        }
        printf "%s rps=%s p50_ms=%s p99_ms=%s errors=%s rss_kb=%s n=%d\n", \
            k, med(a1, nw), med(a2, nw), med(a3, nw), med(a4, nw), med(a5, nw), nw
    }
}
' "$OUT_DIR/runs.tsv"
