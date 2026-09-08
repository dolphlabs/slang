#!/bin/sh
# Raw-throughput HTTP remasure: slang_opt / Go net / C / Rust tokio.
# Same 200B close body as bench/http/main.sl; does not touch that file.
# Usage: HTTP_ROUNDS=3 HTTP_DUR=10s ./bench/run_http_opt.sh

set -eu
cd "$(dirname "$0")/.."

ROUNDS="${HTTP_ROUNDS:-3}"
DUR="${HTTP_DUR:-10s}"
CONCS="${HTTP_CONCS:-50 200}"
SL_PORT="${HTTP_SL_OPT_PORT:-18190}"
GO_PORT="${HTTP_GO_RAW_PORT:-18191}"
C_PORT="${HTTP_C_OPT_PORT:-18192}"
RS_PORT="${HTTP_RS_RAW_PORT:-18193}"
OUT_DIR=/tmp/slang_http_opt
mkdir -p "$OUT_DIR"
: >"$OUT_DIR/runs.tsv"
: >"$OUT_DIR/skipped.txt"

SL_BIN=/tmp/sl_bench_http_opt
GO_BIN=/tmp/go_bench_http_raw
C_BIN=/tmp/c_bench_http
LG_BIN=/tmp/http_loadgen
RS_DIR=bench/http/rust_raw
RS_BIN="$RS_DIR/target/release/http_bench_raw"

export HTTP_ACCEPTORS="${HTTP_ACCEPTORS:-$(nproc 2>/dev/null || echo 1)}"
export SLANG_PREEMPT_QUANTUM_MS="${SLANG_PREEMPT_QUANTUM_MS:-50}"
export SLANG_PREEMPT_TICK_MS="${SLANG_PREEMPT_TICK_MS:-10}"

if [ ! -x ./slangc ]; then
    make slangc
fi

skip() {
    echo "skip $1: $2" | tee -a "$OUT_DIR/skipped.txt"
}

kill_bin() {
    pkill -KILL -f "$1" 2>/dev/null || true
}

kill_port() {
    p=$1
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    fi
}

HAVE_SL=0
HAVE_GO=0
HAVE_C=0
HAVE_RS=0

cleanup() {
    [ "$HAVE_SL" -eq 1 ] && kill_bin "$SL_BIN"
    [ "$HAVE_GO" -eq 1 ] && kill_bin "$GO_BIN"
    [ "$HAVE_C" -eq 1 ] && kill_bin "$C_BIN"
    [ "$HAVE_RS" -eq 1 ] && kill_bin "$RS_BIN"
    kill_port "$SL_PORT"
    kill_port "$GO_PORT"
    kill_port "$C_PORT"
    kill_port "$RS_PORT"
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

echo "=== compile (raw axis) ==="
if c_sl=$(time_sec ./slangc bench/http_opt/main.sl -o "$SL_BIN"); then
    HAVE_SL=1
else
    skip slang_opt "slangc failed"
    c_sl="fail"
fi
if command -v go >/dev/null 2>&1 && c_go=$(time_sec go build -o "$GO_BIN" bench/http/go_raw/main.go); then
    HAVE_GO=1
else
    skip go_raw "go missing or build failed"
    c_go="fail"
fi
if c_cc=$(time_sec cc -O3 -flto -std=c11 bench/http/main.c -lpthread -o "$C_BIN"); then
    HAVE_C=1
else
    skip c "cc failed"
    c_cc="fail"
fi
if command -v go >/dev/null 2>&1; then
    go build -o "$LG_BIN" bench/http/loadgen.go
fi
c_rs="fail"
if command -v cargo >/dev/null 2>&1; then
    if c_rs=$(time_sec cargo build --release --manifest-path "$RS_DIR/Cargo.toml"); then
        HAVE_RS=1
    else
        skip rust_raw "cargo build failed"
        c_rs="fail"
    fi
else
    skip rust_raw "cargo missing"
fi

printf 'compile_s slang_opt=%s go_raw=%s cc_O3_lto=%s rust_tokio_raw=%s\n' \
    "$c_sl" "$c_go" "$c_cc" "$c_rs"
echo "$c_sl $c_go $c_cc $c_rs" >"$OUT_DIR/compile.txt"
echo "HTTP_ACCEPTORS=$HTTP_ACCEPTORS SLANG_PREEMPT_QUANTUM_MS=$SLANG_PREEMPT_QUANTUM_MS SLANG_PREEMPT_TICK_MS=$SLANG_PREEMPT_TICK_MS"

LANGS=""
[ "$HAVE_SL" -eq 1 ] && LANGS="$LANGS slang_opt"
[ "$HAVE_GO" -eq 1 ] && LANGS="$LANGS go_raw"
[ "$HAVE_C" -eq 1 ] && LANGS="$LANGS c"
[ "$HAVE_RS" -eq 1 ] && LANGS="$LANGS rust_raw"
LANGS=$(echo "$LANGS" | sed 's/^ *//')

nproc=$(nproc 2>/dev/null || echo 4)
wrk_threads() {
    c=$1
    t=$nproc
    if [ "$t" -gt "$c" ]; then
        t=$c
    fi
    echo "$t"
}

rss_kb() {
    pid=$1
    awk '/^VmHWM:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || echo "?"
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

to_ms() {
    awk -v s="$1" '
    BEGIN {
        if (s ~ /us$/) { gsub(/us/, "", s); print s/1000; exit }
        if (s ~ /ms$/) { gsub(/ms/, "", s); print s+0; exit }
        if (s ~ /s$/)  { gsub(/s/, "", s); print s*1000; exit }
        print s+0
    }'
}

run_load() {
    port=$1
    conc=$2
    out=$3
    url="http://127.0.0.1:${port}/"
    if command -v wrk >/dev/null 2>&1; then
        t=$(wrk_threads "$conc")
        wrk -t"$t" -c"$conc" -d"$DUR" --latency "$url" >"$out" 2>&1 || true
        rps=$(awk '/^Requests\/sec:/ { print $2 }' "$out")
        p50s=$(awk '/^[[:space:]]*50%/ { print $2; exit }' "$out")
        p99s=$(awk '/^[[:space:]]*99%/ { print $2; exit }' "$out")
        p50=$(to_ms "${p50s:-0}")
        p99=$(to_ms "${p99s:-0}")
        err=$(awk '
            /Socket errors:/ {
                s=$0; gsub(/[^0-9 ]/, " ", s);
                n=split(s, a, " ");
                t=0; for (i=1;i<=n;i++) t+=a[i];
                print t; found=1
            }
            /Non-2xx or 3xx responses:/ { e=$NF }
            END { if (!found) print 0+e }
        ' "$out")
    else
        "$LG_BIN" -url "$url" -c "$conc" -d "$DUR" >"$out" 2>&1 || true
        rps=$(sed -n 's/.*rps=\([0-9.]*\).*/\1/p' "$out")
        p50=$(sed -n 's/.*p50_ms=\([0-9.]*\).*/\1/p' "$out")
        p99=$(sed -n 's/.*p99_ms=\([0-9.]*\).*/\1/p' "$out")
        err=$(sed -n 's/.*errors=\([0-9]*\).*/\1/p' "$out")
    fi
    printf '%s %s %s %s' "${rps:-0}" "${p50:-0}" "${p99:-0}" "${err:-0}"
}

start_named() {
    name=$1
    case $name in
        slang_opt)
            kill_port "$SL_PORT"
            HTTP_PORT="$SL_PORT" "$SL_BIN" >"$OUT_DIR/slang_opt.log" 2>&1 &
            echo $!
            ;;
        go_raw)
            kill_port "$GO_PORT"
            HTTP_PORT="$GO_PORT" "$GO_BIN" >"$OUT_DIR/go_raw.log" 2>&1 &
            echo $!
            ;;
        c)
            kill_port "$C_PORT"
            HTTP_PORT="$C_PORT" "$C_BIN" >"$OUT_DIR/c.log" 2>&1 &
            echo $!
            ;;
        rust_raw)
            kill_port "$RS_PORT"
            HTTP_PORT="$RS_PORT" "$RS_BIN" >"$OUT_DIR/rust_raw.log" 2>&1 &
            echo $!
            ;;
    esac
}

port_for() {
    name=$1
    case $name in
        slang_opt) echo "$SL_PORT" ;;
        go_raw) echo "$GO_PORT" ;;
        c) echo "$C_PORT" ;;
        rust_raw) echo "$RS_PORT" ;;
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
        if [ "$name" = "slang_opt" ] && [ -f "$OUT_DIR/slang_opt.log" ]; then
            tail -n 20 "$OUT_DIR/slang_opt.log" || true
        fi
        printf '%s\t%s\t%s\t0\t0\t0\t1\t?\n' "$name" "$round" "$conc" >>"$OUT_DIR/runs.tsv"
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return
    fi
    blen=$(wc -c < /tmp/http_probe.body | tr -d ' ')
    load_out="$OUT_DIR/${name}_r${round}_c${conc}.wrk"
    set -- $(run_load "$port" "$conc" "$load_out")
    rps=$1; p50=$2; p99=$3; err=$4
    rss=$(rss_kb "$pid")
    printf '%s conc=%s rps=%s p50_ms=%s p99_ms=%s errors=%s rss_kb=%s body=%s\n' \
        "$name" "$conc" "$rps" "$p50" "$p99" "$err" "$rss" "$blen"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$round" "$conc" "$rps" "$p50" "$p99" "$err" "$rss" >>"$OUT_DIR/runs.tsv"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.15
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 0.2
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

echo "http opt bench duration=$DUR concs=$CONCS rounds=$ROUNDS"
echo "langs=$LANGS"
echo "loadgen=$(command -v wrk || echo "$LG_BIN")"
echo "axis=raw-throughput"

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
