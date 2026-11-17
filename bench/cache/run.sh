#!/bin/sh
# stdlib/cache against Go's hashicorp/golang-lru/v2 and ristretto, on
# CPUs 0-3 (Linux, taskset), 4 workers / GOMAXPROCS=4, in ABBA rounds.
# Each run's result, and its peak RSS.
#
#     SLANGC=./slangc ROUNDS=4 sh bench/cache/run.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cache-bench.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ROUNDS=${ROUNDS:-4}
slangc=${SLANGC:-$ROOT/slangc}
(cd "$TMP" && "$slangc" "$ROOT/bench/cache/main.sl" -o "$TMP/slang" >/dev/null 2>&1)
(cd "$ROOT/bench/cache/go" && go build -o "$TMP/go" .)

one() {
    name=$1; shift
    /usr/bin/time -f "%M" -o "$TMP/rss" taskset -c 0-3 env SLANG_WORKERS=4 GOMAXPROCS=4 "$@" >"$TMP/out"
    printf '%-10s %-9s %-40s rss_mb=%s\n' "$name" "$mode" "$(cat "$TMP/out")" "$(awk '{printf "%.1f", $1/1024}' "$TMP/rss")"
}

for round in $(seq "$ROUNDS"); do
    for mode in single parallel fill; do
        if [ $((round % 2)) -eq 1 ]; then
            one slang "$TMP/slang" "$mode"; one go-lru "$TMP/go" lru "$mode"; one ristretto "$TMP/go" ristretto "$mode"
        else
            one ristretto "$TMP/go" ristretto "$mode"; one go-lru "$TMP/go" lru "$mode"; one slang "$TMP/slang" "$mode"
        fi
    done
done
