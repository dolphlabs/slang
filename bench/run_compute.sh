#!/bin/sh
# Alternate-order compute bench: slang vs Go vs C.
# Usage: CC_TASKS=200 CC_WORK=8000 CC_ALLOC=50 ./bench/run_compute.sh
# Prints one RESULT line per run, then medians. Pair order flips each round.

set -eu
cd "$(dirname "$0")/.."

TASKS="${CC_TASKS:-200}"
WORK="${CC_WORK:-8000}"
ALLOC="${CC_ALLOC:-50}"
ROUNDS="${CC_ROUNDS:-3}"
export CC_TASKS="$TASKS" CC_WORK="$WORK" CC_ALLOC="$ALLOC"

if [ ! -x ./slangc ]; then
    make slangc
fi
./slangc stress_test/programs/concurrent_compute/main.sl -o /tmp/sl_bench_compute
cc -O2 -std=c11 bench/compute/main.c -lpthread -o /tmp/c_bench_compute
go build -o /tmp/go_bench_compute bench/compute/main.go

run_one() {
    name=$1
    bin=$2
    out=$3
    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l "$bin" >"$out" 2>"$out.time"
        rss=$(awk '/maximum resident set size/ { print $1; exit }' "$out.time")
    else
        "$bin" >"$out"
        rss="n/a"
    fi
    wall=$(grep '^RESULT' "$out" | sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p')
    printf '%s wall_ms=%s rss=%s\n' "$name" "${wall:-?}" "${rss:-?}"
}

echo "compute bench tasks=$TASKS work=$WORK alloc=$ALLOC rounds=$ROUNDS"
echo "order alternates each round (see todo.md measurement note)"
r=1
while [ "$r" -le "$ROUNDS" ]; do
    echo "-- round $r --"
    if [ $((r % 2)) -eq 1 ]; then
        run_one slang /tmp/sl_bench_compute /tmp/sl_bench_compute.out
        run_one go /tmp/go_bench_compute /tmp/go_bench_compute.out
        run_one c /tmp/c_bench_compute /tmp/c_bench_compute.out
    else
        run_one c /tmp/c_bench_compute /tmp/c_bench_compute.out
        run_one go /tmp/go_bench_compute /tmp/go_bench_compute.out
        run_one slang /tmp/sl_bench_compute /tmp/sl_bench_compute.out
    fi
    r=$((r + 1))
done
