#!/usr/bin/env bash
# Isolated, matched Slang/Go measurements for the four PostgreSQL API routes.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
REPORTER=$ROOT/bench/suite/lib/pg_routes_report.py

usage() {
    cat <<'EOF'
Usage: bench/suite/run_pg_routes.sh --plan | --help | (no arguments)

Full run defaults: 1M users, 20M orders, 64/512 clients, 3 ABBA rounds,
5s warmup and 15s samples. SCALE=quick runs 20K/400K, one round, 64 clients,
2s warmup and 5s samples. RESEED=1 replaces tables in the local `bench`
database; otherwise a mismatched non-empty database is left untouched.
Results go to bench/results/pg-routes-<run id>/.

Measurement requires a dedicated Ubuntu 24.04 x86-64 VPS with four available
CPUs, at least 15GiB visible RAM, 20GiB free on the PostgreSQL volume, and
PostgreSQL 16 pinned to the first three allowed CPUs. Latgen uses the fourth.
EOF
}

if [ "${1:-}" = --help ]; then usage; exit 0; fi
SCALE=${SCALE:-full}
case "$SCALE" in
    full) USERS=1000000; ORDERS=20000000; ROUNDS=${ROUNDS:-3}; DURATION=${DURATION:-15s}; WARMUP=${WARMUP:-5s}; CONCURRENCIES=${CONCURRENCIES:-"64 512"} ;;
    quick) USERS=20000; ORDERS=400000; ROUNDS=${ROUNDS:-1}; DURATION=${DURATION:-5s}; WARMUP=${WARMUP:-2s}; CONCURRENCIES=${CONCURRENCIES:-64} ;;
    *) echo "SCALE must be full or quick" >&2; exit 2 ;;
esac
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(hostname -s)}
OUT=${OUT:-$ROOT/bench/results/pg-routes-$RUN_ID}
DATABASE_URL=${DATABASE_URL:-postgres://bench@127.0.0.1:5432/bench?sslmode=disable}
export PGPASSWORD=${PGPASSWORD:-bench}
PORT=${PORT:-18080}
MIN_FREE_GB=${MIN_FREE_GB:-20}
LOADGEN_BUSY_LIMIT=${LOADGEN_BUSY_LIMIT:-0.95}
STEAL_LIMIT_PCT=${STEAL_LIMIT_PCT:-2.0}
RESEED=${RESEED:-0}
DB_POOL_TOTAL=64
BIN=$ROOT/bench/.build/pg-routes
DATA=$ROOT/bench/.data/pg-routes

if [ "${1:-}" = --plan ]; then
    python3 - "$SCALE" "$USERS" "$ORDERS" "$ROUNDS" "$DURATION" "$WARMUP" "$CONCURRENCIES" "$OUT" <<'PY'
import json, sys
scale, users, orders, rounds, duration, warmup, conns, out = sys.argv[1:]
print(json.dumps({"scale": scale, "seed": {"users": int(users), "orders": int(orders)},
    "routes": ["point", "orders", "summary", "insert"],
    "concurrencies": [int(x) for x in conns.split()], "rounds": int(rounds),
    "samples": 4 * len(conns.split()) * int(rounds) * 4,
    "warmup": warmup, "duration": duration,
    "order": "Slang/Go/Go/Slang; reverse on even rounds",
    "server_cpus": "first three allowed CPUs", "loadgen_cpu": "fourth allowed CPU",
    "builds": ["Slang API", "Go API", "latgen"],
    "output": out, "database_url": "postgres://bench@127.0.0.1:5432/bench",
    "metrics": ["RPS and p50/p90/p99/p99.9", "pool wait and client query/decode",
                "pg_stat_statements", "API/PostgreSQL/loadgen CPU and RSS", "CPU steal"]}, indent=2))
PY
    exit 0
fi
[ "$#" -eq 0 ] || { usage >&2; exit 2; }
fail() { echo "pg-routes: $*" >&2; exit 1; }

[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "RUN_ID must be 1-64 letters, digits, dots, underscores, or hyphens"
OUT=$(python3 - "$ROOT" "$OUT" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
allowed = root / "bench" / "results"
if allowed not in out.parents:
    raise SystemExit(1)
print(out)
PY
 ) || fail "OUT must resolve to a new subdirectory of bench/results"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] && [ "$ROUNDS" -le 10 ] || fail "ROUNDS must be between 1 and 10"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "PORT must be an unprivileged port from 1024 to 65535"
[[ "$MIN_FREE_GB" =~ ^[1-9][0-9]*$ ]] && [ "$MIN_FREE_GB" -le 1000 ] || fail "MIN_FREE_GB must be from 1 to 1000"
[[ "$RESEED" = 0 || "$RESEED" = 1 ]] || fail "RESEED must be 0 or 1"
python3 - "$LOADGEN_BUSY_LIMIT" "$STEAL_LIMIT_PCT" <<'PY' || fail "invalid load-generator or CPU-steal threshold"
import math, sys
try: busy, steal = map(float, sys.argv[1:])
except ValueError: raise SystemExit(1)
raise SystemExit(0 if math.isfinite(busy) and 0 < busy <= 1 and math.isfinite(steal) and 0 <= steal <= 100 else 1)
PY

[ "$(uname -s)" = Linux ] || fail "measurement requires Linux; --plan is portable"
for cmd in make go python3 psql taskset setsid flock curl; do command -v "$cmd" >/dev/null 2>&1 || fail "missing $cmd; run setup_pg_routes_host.sh"; done
[[ "$(go version)" == *"go1.24.1 "* ]] || fail "Go 1.24.1 required for the matched comparison; found $(go version)"
read -r -a CPUS <<<"$(python3 -c 'import os; print(" ".join(map(str, sorted(os.sched_getaffinity(0)))))')"
[ "${#CPUS[@]}" -eq 4 ] || fail "expected four available CPUs; found ${CPUS[*]}"
SERVER_CPUS="${CPUS[0]},${CPUS[1]},${CPUS[2]}"; LOADGEN_CPU=${CPUS[3]}; WORKERS=3
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
[ "$MEM_KB" -ge $((15 * 1024 * 1024)) ] || fail "expected 16GB RAM; visible memory is ${MEM_KB}kB"
read -r -a CONCS <<<"$CONCURRENCIES"
[ "${#CONCS[@]}" -gt 0 ] || fail "CONCURRENCIES cannot be empty"
for n in "${CONCS[@]}"; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ "$n" -le 2048 ] || fail "concurrency must be from 1 to 2048: $n"
done
python3 - "$DURATION" "$WARMUP" <<'PY' || fail "DURATION must be 1-300 seconds and WARMUP 1-120 seconds"
import re, sys
p = re.compile(r"^([1-9][0-9]*)(ns|us|µs|ms|s|m|h)$")
factors = {"ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}
values = []
for text in sys.argv[1:]:
    match = p.fullmatch(text)
    if not match: raise SystemExit(1)
    values.append(int(match[1]) * factors[match[2]])
raise SystemExit(0 if 1 <= values[0] <= 300 and 1 <= values[1] <= 120 else 1)
PY
python3 - "$DATABASE_URL" <<'PY' || fail "DATABASE_URL must point to the local database named bench"
import sys
from urllib.parse import urlsplit
if len(sys.argv[1]) > 2048: raise SystemExit(1)
u = urlsplit(sys.argv[1])
raise SystemExit(0 if u.scheme in ("postgres", "postgresql") and u.username == "bench" and u.password is None and
                 u.hostname in ("localhost", "127.0.0.1", "::1") and u.path == "/bench" and
                 u.query in ("", "sslmode=disable") and not u.fragment else 1)
PY
# The Slang PG driver reads credentials from the URL; PostgreSQL CLI and Go
# use PGPASSWORD. Add the same password only to the Slang process environment.
SLANG_DATABASE_URL=$(python3 - "$DATABASE_URL" <<'PY'
import os, sys
from urllib.parse import quote, urlsplit, urlunsplit
u = urlsplit(sys.argv[1])
password = os.environ.get("PGPASSWORD", "")
if not password or len(password) > 1024: raise SystemExit(1)
host = u.hostname or ""
if ":" in host: host = f"[{host}]"
if u.port: host += f":{u.port}"
netloc = f"{quote(u.username or '', safe='')}:{quote(password, safe='')}@{host}"
print(urlunsplit((u.scheme, netloc, u.path, u.query, "")))
PY
) || fail "PGPASSWORD must contain 1-1024 characters for the Slang database URL"

exec 9>"/tmp/slang-pg-routes-$(id -u).lock"
flock -n 9 || fail "another targeted benchmark is running"
[ ! -e "$OUT" ] || fail "output already exists: $OUT"
mkdir -p "$OUT/raw" "$BIN" "$DATA"
LOG=$OUT/run.log
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) starting $RUN_ID" >"$LOG"
python3 - "$PORT" <<'PY' || fail "API port $PORT is occupied"
import socket, sys
s = socket.socket(); s.settimeout(.25)
raise SystemExit(1 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 0)
PY

PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)
SERVER_VERSION=$("${PSQL[@]}" -At -c 'SHOW server_version_num' 2>/dev/null) || fail "cannot connect to local PostgreSQL"
[[ "$SERVER_VERSION" == 16* ]] || fail "requires PostgreSQL 16; found version_num=$SERVER_VERSION"
EXT_VERSION=$("${PSQL[@]}" -At -c "SELECT coalesce((SELECT extversion FROM pg_extension WHERE extname='pg_stat_statements'), '')")
[ -n "$EXT_VERSION" ] || fail "pg_stat_statements is missing from database bench"
PGDATA=$("${PSQL[@]}" -At -c 'SHOW data_directory')
PG_PID=$(head -n 1 "$PGDATA/postmaster.pid")
[[ "$PG_PID" =~ ^[1-9][0-9]*$ ]] || fail "cannot find PostgreSQL postmaster PID"
PG_ALLOWED=$(awk '/^Cpus_allowed_list:/ {print $2}' "/proc/$PG_PID/status")
python3 - "$PG_ALLOWED" "${CPUS[0]} ${CPUS[1]} ${CPUS[2]}" <<'PY' || fail "PostgreSQL affinity is $PG_ALLOWED, expected the first three allowed CPUs"
import sys
def expand(s):
    out = set()
    for p in s.split(","):
        if "-" in p:
            a, b = map(int, p.split("-", 1)); out.update(range(a, b + 1))
        elif p: out.add(int(p))
    return out
raise SystemExit(0 if expand(sys.argv[1]) == set(map(int, sys.argv[2].split())) else 1)
PY
PG_FREE_KB=$(df -Pk "$PGDATA" | awk 'NR == 2 {print $4}')
[ "$PG_FREE_KB" -ge $((MIN_FREE_GB * 1024 * 1024)) ] || fail "need ${MIN_FREE_GB}GiB free on PostgreSQL volume; found $((PG_FREE_KB / 1024 / 1024))GiB"

TABLE_FLAGS=$("${PSQL[@]}" -At -F ':' -c "SELECT to_regclass('public.bench_meta') IS NOT NULL,to_regclass('public.users') IS NOT NULL,to_regclass('public.orders') IS NOT NULL")
IFS=: read -r META_EXISTS USERS_EXISTS ORDERS_EXISTS <<<"$TABLE_FLAGS"
if [ "$META_EXISTS" = t ]; then
    SEED_STATE=$("${PSQL[@]}" -At -F ':' -c "SELECT coalesce((SELECT v FROM bench_meta WHERE k='users'),0),coalesce((SELECT v FROM bench_meta WHERE k='orders'),0),to_regclass('public.users') IS NOT NULL,to_regclass('public.orders') IS NOT NULL")
else
    SEED_STATE="0:0:$USERS_EXISTS:$ORDERS_EXISTS"
fi
if [ "$SEED_STATE" != "$USERS:$ORDERS:t:t" ]; then
    [ "$RESEED" = 1 ] || [ "$SEED_STATE" = "0:0:f:f" ] || fail "database seed is '$SEED_STATE'; set RESEED=1 only if local bench tables may be replaced"
    echo "preparing schema and seed users=$USERS orders=$ORDERS" | tee -a "$LOG"
    "${PSQL[@]}" -f bench/suite/db/schema.sql >>"$LOG" 2>&1
    "${PSQL[@]}" -v users="$USERS" -v orders="$ORDERS" -f bench/suite/db/seed.sql >>"$LOG" 2>&1
fi
ACTUAL_ROWS=$("${PSQL[@]}" -At -F ':' -c "SELECT (SELECT count(*) FROM users),(SELECT count(*) FROM orders)")
[ "$ACTUAL_ROWS" = "$USERS:$ORDERS" ] || fail "row counts $ACTUAL_ROWS do not match requested seed $USERS:$ORDERS"

QUOTE_DIR=$DATA/quotes
[ -f "$QUOTE_DIR/quote_7.json" ] || python3 bench/suite/lib/gen_quote.py "$QUOTE_DIR" 8 2000
echo "building Slang API, Go API, and latgen only" | tee -a "$LOG"
make -s slangc >"$OUT/raw/build-slangc.log" 2>&1 || fail "Slang compiler build failed; see raw/build-slangc.log"
(cd "$BIN" && "$ROOT/slangc" "$ROOT/bench/suite/api/slang/main.sl" -o slang-api) >"$OUT/raw/build-slang-api.log" 2>&1 || fail "Slang API build failed; see raw/build-slang-api.log"
(cd "$ROOT/bench/suite/api/go" && go build -trimpath -ldflags='-s -w' -o "$BIN/go-api" .) >"$OUT/raw/build-go-api.log" 2>&1 || fail "Go API build failed; see raw/build-go-api.log"
go build -trimpath -o "$BIN/latgen" "$ROOT/bench/latgen/main.go" >"$OUT/raw/build-latgen.log" 2>&1 || fail "latgen build failed; see raw/build-latgen.log"

DATABASE_URL_SAFE=$(python3 - "$DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit
u = urlsplit(sys.argv[1]); host = u.hostname or "localhost"
if u.port: host += f":{u.port}"
print(urlunsplit((u.scheme, ("***@" if u.username else "") + host, u.path, "", "")))
PY
)
CONCS_JSON=$(printf '%s\n' "${CONCS[@]}" | python3 -c 'import json,sys; print(json.dumps([int(x) for x in sys.stdin.read().split()]))')
PG_FREE_BYTES=$(df -Pk "$PGDATA" | awk 'NR == 2 {print $4 * 1024}')
python3 - "$OUT/env.json" "$RUN_ID" "$SCALE" "$USERS" "$ORDERS" "$ROUNDS" "$DURATION" "$WARMUP" "$CONCS_JSON" \
    "$DB_POOL_TOTAL" "$SERVER_CPUS" "$LOADGEN_CPU" "$DATABASE_URL_SAFE" "$EXT_VERSION" "$PG_FREE_BYTES" "$SERVER_VERSION" <<'PY'
import json, os, platform, subprocess, sys
from datetime import datetime, timezone
out, run_id, scale, users, orders, rounds, duration, warmup, concs, pool, cpus, loadgen, db, ext, free, dbver = sys.argv[1:]
def cmd(*args):
    try: return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).splitlines()[0]
    except (OSError, subprocess.CalledProcessError, IndexError): return "unavailable"
try:
    sha = cmd("git", "rev-parse", "HEAD")
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip())
except (OSError, subprocess.CalledProcessError): sha, dirty = "unknown", True
cpu = next((x.split(":", 1)[1].strip() for x in open("/proc/cpuinfo") if x.startswith("model name")), "unknown")
memory = int(next(x.split()[1] for x in open("/proc/meminfo") if x.startswith("MemTotal:")))
data = {"schema": "slang-pg-routes/1", "run_id": run_id,
    "started_utc": datetime.now(timezone.utc).isoformat(), "git_sha": sha, "git_dirty": dirty,
    "host": {"kernel": platform.platform(), "cpu_model": cpu, "memory_total_kb": memory,
             "postgres_free_bytes_at_start": int(free), "postgres_cpus": cpus, "loadgen_cpu": int(loadgen)},
    "database": {"url": db, "server_version_num": int(dbver), "pg_stat_statements": ext, "pool_size": int(pool)},
    "seed": {"scale": scale, "users": int(users), "orders": int(orders)},
    "matrix": {"rounds": int(rounds), "duration": duration, "warmup": warmup,
               "concurrencies": json.loads(concs), "routes": ["point", "orders", "summary", "insert"]},
    "toolchains": {"slangc": cmd("./slangc", "--version"), "go": cmd("go", "version"),
                    "cc": cmd("cc", "--version"), "psql": cmd("psql", "--version")}}
with open(out, "w") as f: json.dump(data, f, indent=2); f.write("\n")
PY

reset_pg_stats() {
    "${PSQL[@]}" -At -c "SELECT pg_stat_statements_reset(0::oid,(SELECT oid FROM pg_database WHERE datname=current_database()),0::bigint)" >/dev/null
}
snapshot_pg_stats() { "${PSQL[@]}" -A -F $'\t' -P footer=off -f bench/suite/api/pg_profile_stats.sql >"$1"; }

API_PID=""; LATGEN_PID=""; API_SAMPLE=""; PG_SAMPLE=""; LOAD_SAMPLE=""
stop_group() {
    local p=${1:-}; [ -n "$p" ] || return 0
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep .1; done
    kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
}
SAMPLER_PID=""
start_sampler() { python3 bench/suite/lib/sampler.py "$1" "$2" .1 >"$3" 2>&1 & SAMPLER_PID=$!; }
stop_sampler() { local p=${1:-}; [ -n "$p" ] || return 0; kill -TERM "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; }
cleanup() { stop_group "$LATGEN_PID"; stop_sampler "$API_SAMPLE"; stop_sampler "$PG_SAMPLE"; stop_sampler "$LOAD_SAMPLE"; stop_group "$API_PID"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

start_api() {
    local lang=$1 logfile=$2
    if [ "$lang" = slang ]; then
        setsid taskset -c "$SERVER_CPUS" env DATABASE_URL="$SLANG_DATABASE_URL" DB_POOL_TOTAL=64 PG_PROFILE=1 PORT="$PORT" WORKERS=3 SLANG_WORKERS=3 "$BIN/slang-api" >"$logfile" 2>&1 &
    else
        setsid taskset -c "$SERVER_CPUS" env DATABASE_URL="$DATABASE_URL" DB_POOL_TOTAL=64 PG_PROFILE=1 PORT="$PORT" WORKERS=3 GOMAXPROCS=3 "$BIN/go-api" >"$logfile" 2>&1 &
    fi
    API_PID=$!
}
stop_api() { stop_group "$API_PID"; API_PID=""; }
wait_health() {
    for _ in $(seq 1 100); do
        curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" -o /dev/null 2>/dev/null && return 0
        kill -0 "$API_PID" 2>/dev/null || return 1
        sleep .1
    done
    return 1
}
steal_ticks() { awk '/^cpu /{print $9 + 0; exit}' /proc/stat; }
total_ticks() { awk '/^cpu /{s=0; for (i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/stat; }

echo "checking Slang and Go API conformance" | tee -a "$LOG"
for lang in slang go; do
    start_api "$lang" "$OUT/raw/conformance-$lang-server.log"
    wait_health || fail "$lang API did not become healthy"
    if DATABASE_URL="$DATABASE_URL" python3 bench/suite/lib/conformance.py "http://127.0.0.1:$PORT" "$QUOTE_DIR" >"$OUT/raw/conformance-$lang.log" 2>&1; then
        echo "$lang conformance passed" | tee -a "$LOG"
    else
        stop_api; cat "$OUT/raw/conformance-$lang.log" >&2; fail "$lang conformance failed"
    fi
    stop_api
done
"${PSQL[@]}" -f bench/suite/db/reset.sql >>"$LOG" 2>&1

sample_one() {
    local route=$1 path=$2 body=$3 status=$4 clients=$5 round=$6 pos=$7 lang=$8
    local dir="$OUT/raw/$route/c$clients/round$(printf '%02d' "$round")/$(printf '%02d' "$pos")-$lang"
    mkdir -p "$dir"
    if [ "$route" = insert ]; then "${PSQL[@]}" -f bench/suite/db/reset.sql >"$dir/reset-before.log" 2>&1; fi
    echo "warmup $route c$clients round$round $lang $pos" | tee -a "$LOG"
    start_api "$lang" "$dir/server.log"
    wait_health || fail "$lang API unhealthy for $route"
    local -a req=("$BIN/latgen" -addr "127.0.0.1:$PORT" -path "$path" -c "$clients" -d "$WARMUP" -pg-profile -expect-status "$status")
    [ -z "$body" ] || req+=(-body "$body")
    taskset -c "$LOADGEN_CPU" "${req[@]}" >"$dir/warmup.log" 2>&1 || fail "warmup failed: $dir"
    python3 "$REPORTER" check "$dir/warmup.log" "$status" || fail "warmup had bad responses: $dir"
    if [ "$route" = insert ]; then "${PSQL[@]}" -f bench/suite/db/reset.sql >"$dir/reset-after-warmup.log" 2>&1; fi
    reset_pg_stats
    snapshot_pg_stats "$dir/pg-before.tsv"

    start_sampler "$API_PID" "$dir/api-sampler.json" "$dir/api-sampler.log"; API_SAMPLE=$SAMPLER_PID
    start_sampler "$PG_PID" "$dir/postgres-sampler.json" "$dir/postgres-sampler.log"; PG_SAMPLE=$SAMPLER_PID
    local s0 t0 s1 t1 rc=0
    s0=$(steal_ticks); t0=$(total_ticks)
    req=("$BIN/latgen" -addr "127.0.0.1:$PORT" -path "$path" -c "$clients" -d "$DURATION" -pg-profile -expect-status "$status" -dump "$dir/latencies.csv")
    [ -z "$body" ] || req+=(-body "$body")
    taskset -c "$LOADGEN_CPU" "${req[@]}" >"$dir/latgen.log" 2>&1 &
    LATGEN_PID=$!
    start_sampler "$LATGEN_PID" "$dir/loadgen-sampler.json" "$dir/loadgen-sampler.log"; LOAD_SAMPLE=$SAMPLER_PID
    wait "$LATGEN_PID" || rc=$?
    LATGEN_PID=""
    stop_sampler "$LOAD_SAMPLE"; LOAD_SAMPLE=""
    stop_sampler "$API_SAMPLE"; API_SAMPLE=""
    stop_sampler "$PG_SAMPLE"; PG_SAMPLE=""
    s1=$(steal_ticks); t1=$(total_ticks)
    snapshot_pg_stats "$dir/pg-after.tsv"
    stop_api
    python3 - "$dir/meta.json" "$route" "$path" "$clients" "$round" "$pos" "$lang" "$status" "$DURATION" "$WARMUP" "$rc" "$s0" "$t0" "$s1" "$t1" "$SERVER_CPUS" "$LOADGEN_CPU" <<'PY'
import json, sys
out, route, path, clients, rnd, pos, lang, status, duration, warmup, rc, s0, t0, s1, t1, cpus, loadgen = sys.argv[1:]
s0,t0,s1,t1=map(int,(s0,t0,s1,t1)); steal=round(100*(s1-s0)/(t1-t0),3) if t1>t0 else None
with open(out,"w") as f:
    json.dump({"route":route,"path":path,"concurrency":int(clients),"round":int(rnd),"position":int(pos),"language":lang,
        "expected_status":int(status),"duration":duration,"warmup":warmup,"latgen_exit":int(rc),"cpu_steal_pct":steal,
        "server_cpus":cpus,"loadgen_cpu":int(loadgen)},f,indent=2); f.write("\n")
PY
    python3 "$REPORTER" sample "$dir" "$LOADGEN_BUSY_LIMIT" "$STEAL_LIMIT_PCT" || true
    echo "saved $dir" | tee -a "$LOG"
}

echo "starting ABBA matrix: ${#CONCS[@]} client levels, $ROUNDS rounds per route" | tee -a "$LOG"
for route in point orders summary insert; do
    case "$route" in
        point) path=/api/users/7; body=; status=200 ;;
        orders) path=/api/users/7/orders?limit=50; body=; status=200 ;;
        summary) path=/api/users/7/summary; body=; status=200 ;;
        insert) path=/api/orders; body='{"user_id":7,"sku":"SKU-00042","qty":2,"price_cents":1999}'; status=201 ;;
    esac
    for clients in "${CONCS[@]}"; do
        for ((round=1; round<=ROUNDS; round++)); do
            if (( round % 2 )); then order=(slang go go slang); else order=(go slang slang go); fi
            pos=0
            for lang in "${order[@]}"; do
                pos=$((pos+1))
                sample_one "$route" "$path" "$body" "$status" "$clients" "$round" "$pos" "$lang"
            done
        done
    done
done

python3 "$REPORTER" report "$OUT" --loadgen-busy-limit "$LOADGEN_BUSY_LIMIT" --steal-limit-pct "$STEAL_LIMIT_PCT"
echo "Results: $OUT/summary.md"
