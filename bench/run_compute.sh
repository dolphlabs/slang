#!/bin/sh
# Alternate-order compute bench: slang vs Go vs C vs Rust.
# Usage: CC_TASKS=200 CC_WORK=8000 CC_ALLOC=50 ./bench/run_compute.sh
# Prints compile times, one RESULT line per run, then medians.

set -eu
cd "$(dirname "$0")/.."

TASKS="${CC_TASKS:-200}"
WORK="${CC_WORK:-8000}"
ALLOC="${CC_ALLOC:-50}"
ROUNDS="${CC_ROUNDS:-3}"
export CC_TASKS="$TASKS" CC_WORK="$WORK" CC_ALLOC="$ALLOC"

SL_BIN=/tmp/sl_bench_compute
SL_ARENA_BIN=/tmp/sl_bench_compute_arena
GO_BIN=/tmp/go_bench_compute
C_BIN=/tmp/c_bench_compute
RS_BIN=/tmp/rs_bench_compute
OUT_DIR=/tmp/slang_phase_e_compute
mkdir -p "$OUT_DIR"
: >"$OUT_DIR/runs.tsv"

if [ ! -x ./slangc ]; then
    make slangc
fi

time_sec() {
    tf="$OUT_DIR/time.$$"
    if ! /usr/bin/time -f '%e' -o "$tf" "$@"; then
        echo "command failed: $*" >&2
        exit 1
    fi
    cat "$tf"
    rm -f "$tf"
}

echo "=== compile ==="
c_sl=$(time_sec ./slangc stress_test/programs/concurrent_compute/main.sl -o "$SL_BIN")
c_sla=$(time_sec ./slangc bench/compute/arena.sl -o "$SL_ARENA_BIN")
c_go=$(time_sec go build -o "$GO_BIN" bench/compute/main.go)
c_cc=$(time_sec cc -O3 -std=c11 bench/compute/main.c -lpthread -o "$C_BIN")
c_rs=$(time_sec rustc --edition 2021 -C opt-level=3 bench/compute/main.rs -o "$RS_BIN")
printf 'compile_s slang_gc=%s slang_arena=%s go=%s cc_O3=%s rustc_O3=%s\n' \
    "$c_sl" "$c_sla" "$c_go" "$c_cc" "$c_rs"
echo "$c_sl $c_sla $c_go $c_cc $c_rs" >"$OUT_DIR/compile.txt"

run_one() {
    name=$1
    bin=$2
    out=$3
    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l "$bin" >"$out" 2>"$out.time"
        rss_b=$(awk '/maximum resident set size/ { print $1; exit }' "$out.time")
        rss=$((rss_b / 1024))
    else
        /usr/bin/time -f 'RSS_KB=%M' "$bin" >"$out" 2>"$out.time"
        rss=$(sed -n 's/^RSS_KB=//p' "$out.time" | tail -n 1)
    fi
    wall=$(grep '^RESULT' "$out" | sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p')
    tps=$(grep '^RESULT' "$out" | sed -n 's/.*tasks_per_sec=\([0-9]*\).*/\1/p')
    primes=$(grep '^RESULT' "$out" | sed -n 's/.*total_primes=\([0-9]*\).*/\1/p')
    printf '%s wall_ms=%s rss_kb=%s tasks_per_sec=%s total_primes=%s\n' \
        "$name" "${wall:-?}" "${rss:-?}" "${tps:-?}" "${primes:-?}"
    printf '%s\t%s\t%s\t%s\n' "$name" "${wall:-}" "${rss:-}" "${tps:-}" >>"$OUT_DIR/runs.tsv"
}

echo "compute bench tasks=$TASKS work=$WORK alloc=$ALLOC rounds=$ROUNDS"
echo "order rotates each round"
r=1
while [ "$r" -le "$ROUNDS" ]; do
    echo "-- round $r --"
    case $((r % 4)) in
        1)
            run_one slang "$SL_BIN" /tmp/sl_bench_compute.out
            run_one go "$GO_BIN" /tmp/go_bench_compute.out
            run_one c "$C_BIN" /tmp/c_bench_compute.out
            run_one rust "$RS_BIN" /tmp/rs_bench_compute.out
            ;;
        2)
            run_one rust "$RS_BIN" /tmp/rs_bench_compute.out
            run_one c "$C_BIN" /tmp/c_bench_compute.out
            run_one go "$GO_BIN" /tmp/go_bench_compute.out
            run_one slang "$SL_BIN" /tmp/sl_bench_compute.out
            ;;
        3)
            run_one go "$GO_BIN" /tmp/go_bench_compute.out
            run_one rust "$RS_BIN" /tmp/rs_bench_compute.out
            run_one slang "$SL_BIN" /tmp/sl_bench_compute.out
            run_one c "$C_BIN" /tmp/c_bench_compute.out
            ;;
        0)
            run_one c "$C_BIN" /tmp/c_bench_compute.out
            run_one slang "$SL_BIN" /tmp/sl_bench_compute.out
            run_one rust "$RS_BIN" /tmp/rs_bench_compute.out
            run_one go "$GO_BIN" /tmp/go_bench_compute.out
            ;;
    esac
    r=$((r + 1))
done

echo "-- slang arena (no list/map GC; extra, not vs Go maps) --"
run_one slang_arena "$SL_ARENA_BIN" /tmp/sl_bench_compute_arena.out

echo "-- medians (wall_ms, rss_kb, tasks_per_sec) --"
awk -F '\t' '
function med(a, n,    s, i, j, t) {
    for (i = 1; i <= n; i++) s[i] = a[i]
    for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
            if (s[j] + 0 < s[i] + 0) { t = s[i]; s[i] = s[j]; s[j] = t }
    if (n % 2) return s[int(n / 2) + 1]
    return (s[n / 2] + s[n / 2 + 1]) / 2
}
{
    n[$1]++
    w[$1, n[$1]] = $2
    r[$1, n[$1]] = $3
    t[$1, n[$1]] = $4
}
END {
    for (k in n) {
        nw = n[k]
        split("", aw); split("", ar); split("", at)
        for (i = 1; i <= nw; i++) { aw[i] = w[k, i]; ar[i] = r[k, i]; at[i] = t[k, i] }
        printf "%s wall_ms=%s rss_kb=%s tasks_per_sec=%s n=%d\n", \
            k, med(aw, nw), med(ar, nw), med(at, nw), nw
    }
}
' "$OUT_DIR/runs.tsv"
