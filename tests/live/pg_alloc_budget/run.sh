#!/usr/bin/env bash
# Allocation budget for a cached pg.pool_query (tests/live/pg_alloc_budget).
# Needs PG_URL. Fails when N queries cost more than N * PER + SLACK
# allocations over the same program running none.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PER=41
SLACK=50
N=2000
bin=$(mktemp -d)/pg_alloc_budget
log=$(mktemp)
if ! ./slangc tests/live/pg_alloc_budget/main.sl -o "$bin" >"$log" 2>&1; then
    cat "$log"
    echo "FAIL pg.pool_query allocation budget: does not compile"
    exit 1
fi
allocs() {
    ALLOC_BUDGET_N=$1 SLANG_GC_STAT=1 "$bin" 2>&1 >/dev/null |
        tr ' ' '\n' | sed -n 's/^allocs=//p'
}
a0=$(allocs 0)
a1=$(allocs "$N")
used=$((a1 - a0))
limit=$((N * PER + SLACK))
per=$(awk -v u="$used" -v n="$N" 'BEGIN{printf "%.1f", u / n}')
if [ "$used" -gt "$limit" ]; then
    echo "FAIL pg.pool_query allocation budget: $per per query (budget $PER)"
    exit 1
fi
echo "PASS pg.pool_query allocation budget: $per per query (budget $PER)"
