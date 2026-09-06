#!/bin/sh
# Alternate-order HTTP bench: slang (link+arena+wire+spawn) vs Go net/http
# vs C epoll+arena vs Rust tokio/axum.
# Usage: HTTP_ROUNDS=3 HTTP_DUR=10s ./bench/run_http.sh

set -eu
cd "$(dirname "$0")/.."

ROUNDS="${HTTP_ROUNDS:-3}"
DUR="${HTTP_DUR:-10s}"
CONCS="${HTTP_CONCS:-50 200}"
SL_PORT="${HTTP_SL_PORT:-18180}"
GO_PORT="${HTTP_GO_PORT:-18181}"
C_PORT="${HTTP_C_PORT:-18182}"
RS_PORT="${HTTP_RS_PORT:-18183}"
OUT_DIR=/tmp/slang_phase_e_http
mkdir -p "$OUT_DIR"
: >"$OUT_DIR/runs.tsv"

SL_BIN=/tmp/sl_bench_http
GO_BIN=/tmp/go_bench_http
C_BIN=/tmp/c_bench_http
LG_BIN=/tmp/http_loadgen
RS_DIR=bench/http/rust
RS_BIN="$RS_DIR/target/release/http_bench"

if [ ! -x ./slangc ]; then
    make slangc
fi

kill_bin() {
    name=$1
    pkill -KILL -f "$name" 2>/dev/null || true
}

kill_port() {
    p=$1
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    kill_bin "$SL_BIN"
    kill_bin "$GO_BIN"
    kill_bin "$C_BIN"
    kill_bin "$RS_BIN"
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
        echo "command failed: $*" >&2
        exit 1
    fi
    tail -n 1 "$tf"
    rm -f "$tf"
}

echo "=== compile ==="
c_sl=$(time_sec ./slangc bench/http/main.sl -o "$SL_BIN")
c_go=$(time_sec go build -o "$GO_BIN" bench/http/main.go)
c_cc=$(time_sec cc -O3 -flto -std=c11 bench/http/main.c -lpthread -o "$C_BIN")
go build -o "$LG_BIN" bench/http/loadgen.go
(
    cd "$RS_DIR"
    cargo fetch
    cargo clean
)
c_rs=$(time_sec cargo build --release --manifest-path "$RS_DIR/Cargo.toml")
printf 'compile_s slang=%s go=%s cc_O3_lto=%s rust_axum_release=%s\n' \
    "$c_sl" "$c_go" "$c_cc" "$c_rs"
echo "$c_sl $c_go $c_cc $c_rs" >"$OUT_DIR/compile.txt"

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

read_port_from_log() {
    log=$1
    i=0
    while [ "$i" -lt 80 ]; do
        if grep -q '^LISTEN_PORT ' "$log" 2>/dev/null; then
            sed -n 's/^LISTEN_PORT //p' "$log" | head -n 1
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
        slang)
            kill_port "$SL_PORT"
            : >"$OUT_DIR/slang.log"
            if command -v stdbuf >/dev/null 2>&1; then
                HTTP_PORT="$SL_PORT" stdbuf -oL -eL "$SL_BIN" >"$OUT_DIR/slang.log" 2>&1 &
            else
                HTTP_PORT="$SL_PORT" "$SL_BIN" >"$OUT_DIR/slang.log" 2>&1 &
            fi
            echo $!
            ;;
        go)
            kill_port "$GO_PORT"
            HTTP_PORT="$GO_PORT" "$GO_BIN" >"$OUT_DIR/go.log" 2>&1 &
            echo $!
            ;;
        c)
            kill_port "$C_PORT"
            HTTP_PORT="$C_PORT" "$C_BIN" >"$OUT_DIR/c.log" 2>&1 &
            echo $!
            ;;
        rust)
            kill_port "$RS_PORT"
            HTTP_PORT="$RS_PORT" "$RS_BIN" >"$OUT_DIR/rust.log" 2>&1 &
            echo $!
            ;;
    esac
}

port_for() {
    name=$1
    pid=$2
    case $name in
        slang) echo "$SL_PORT" ;;
        go) echo "$GO_PORT" ;;
        c) echo "$C_PORT" ;;
        rust) echo "$RS_PORT" ;;
    esac
}

run_server() {
    name=$1
    conc=$2
    round=$3
    pid=$(start_named "$name")
    port=$(port_for "$name" "$pid")
    if ! wait_http "$port"; then
        echo "$name conc=$conc FAIL not ready (port=${port:-?})"
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

echo "http bench duration=$DUR concs=$CONCS rounds=$ROUNDS"
echo "loadgen=$(command -v wrk || echo "$LG_BIN")"
echo "order rotates each round"

r=1
while [ "$r" -le "$ROUNDS" ]; do
    echo "-- round $r --"
    case $((r % 4)) in
        1) set -- slang go c rust ;;
        2) set -- rust c go slang ;;
        3) set -- go rust slang c ;;
        0) set -- c slang rust go ;;
    esac
    for name in "$@"; do
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
