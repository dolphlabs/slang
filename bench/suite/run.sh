#!/usr/bin/env bash
# Run the benchmark suite (bench/SPEC.md) on this Linux host.
#
#   bench/suite/run.sh                 everything, full scale
#   QUICK=1 bench/suite/run.sh         a minutes-long smoke test at tiny scale
#   TIERS=heavy LANGS="slang go" bench/suite/run.sh
#
# Writes bench/results/<run id>/: env.json, builds.json, correctness.json,
# runs.jsonl (one line per measurement, with its raw log), then
# results.json and summary.md via lib/report.py. See bench/CURSOR.md.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
export ROOT

# ---- configuration -------------------------------------------------------

QUICK=${QUICK:-0}
TIERS=${TIERS:-light,heavy}
LANGS=${LANGS:-"slang go rust c csharp java python bun node"}
ROUNDS=${ROUNDS:-3}
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(hostname -s)}
OUT=${OUT:-$ROOT/bench/results/$RUN_ID}
BIN=${BIN:-$ROOT/bench/.build}
export BIN

DATABASE_URL=${DATABASE_URL:-postgres://bench:bench@127.0.0.1:5432/bench}
PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

if [ "$QUICK" = 1 ]; then
    USERS=${USERS:-20000}; ORDERS=${ORDERS:-400000}
    BATCH_ROWS=${BATCH_ROWS:-2000000}; BATCH_USERS=${BATCH_USERS:-100000}
    HTTP_DUR=${HTTP_DUR:-5s}; API_DUR=${API_DUR:-10s}; WARMUP=${WARMUP:-3s}
    CC_TASKS=${CC_TASKS:-200}; CC_WORK=${CC_WORK:-8000}; CC_ALLOC=${CC_ALLOC:-50}
    ROUNDS=${ROUNDS_QUICK:-1}
else
    USERS=${USERS:-1000000}; ORDERS=${ORDERS:-20000000}
    BATCH_ROWS=${BATCH_ROWS:-100000000}; BATCH_USERS=${BATCH_USERS:-5000000}
    HTTP_DUR=${HTTP_DUR:-30s}; API_DUR=${API_DUR:-60s}; WARMUP=${WARMUP:-15s}
    CC_TASKS=${CC_TASKS:-1000}; CC_WORK=${CC_WORK:-20000}; CC_ALLOC=${CC_ALLOC:-200}
fi
HTTP_CONNS=${HTTP_CONNS:-"50 200"}
API_CONNS=${API_CONNS:-"64 512"}
API_RATES=${API_RATES:-"2000 10000"}
API_SCENARIOS=${API_SCENARIOS:-"mix point quote"}
DB_POOL_TOTAL=${DB_POOL_TOTAL:-64}
DATA=${DATA:-$ROOT/bench/.data}
export USERS ORDERS CC_TASKS CC_WORK CC_ALLOC DATABASE_URL DB_POOL_TOTAL

# CPU split on one machine: the program under test, the load generator and
# the database each get their own cores. Override with explicit lists.
NCPU=$(nproc)
if [ -z "${SERVER_CPUS:-}" ]; then
    half=$((NCPU / 2)); quarter=$((NCPU / 4))
    [ "$quarter" -lt 1 ] && quarter=1
    SERVER_CPUS="0-$((half - 1))"
    LOADGEN_CPUS="$half-$((half + quarter - 1))"
    DB_CPUS="$((half + quarter))-$((NCPU - 1))"
fi
count_cpus() { # "0-3,8" -> 5
    local n=0 part
    for part in ${1//,/ }; do
        if [[ $part == *-* ]]; then n=$((n + ${part#*-} - ${part%-*} + 1)); else n=$((n + 1)); fi
    done
    echo "$n"
}
WORKERS=$(count_cpus "$SERVER_CPUS")
LOADGEN_THREADS=$(count_cpus "$LOADGEN_CPUS")
export WORKERS

# thousands of connections per run: raise the descriptor limit if allowed
ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

mkdir -p "$OUT/raw" "$DATA" "$BIN"
LOG="$OUT/run.log"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
has_tier() { [[ ",$TIERS," == *",$1,"* ]]; }

# shellcheck source=langs.sh
. "$ROOT/bench/suite/langs.sh"

# ---- process control -----------------------------------------------------

SERVER_PID=""
start_server() { # <cpus> <logfile> <command...>
    local cpus=$1 logf=$2; shift 2
    setsid taskset -c "$cpus" bash -c "exec $*" >"$logf" 2>&1 &
    SERVER_PID=$!
}

stop_server() {
    [ -z "$SERVER_PID" ] && return
    kill -TERM -- "-$SERVER_PID" 2>/dev/null
    for _ in $(seq 50); do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.2
    done
    kill -KILL -- "-$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
    sleep 1 # let the port leave TIME_WAIT pressure behind
}
trap 'stop_server; exit 130' INT TERM

wait_http() { # <url> <seconds>
    local url=$1 limit=$2 i
    for i in $(seq $((limit * 5))); do
        curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null && return 0
        kill -0 "$SERVER_PID" 2>/dev/null || return 1
        sleep 0.2
    done
    return 1
}

wait_port() { # <port> <seconds>
    local port=$1 limit=$2 i
    for i in $(seq $((limit * 5))); do
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
        kill -0 "$SERVER_PID" 2>/dev/null || return 1
        sleep 0.2
    done
    return 1
}

SAMPLER_PID=""
sample_start() { # <root pid> <out.json>
    python3 "$ROOT/bench/suite/lib/sampler.py" "$1" "$2" 0.2 &
    SAMPLER_PID=$!
}
sample_stop() {
    [ -n "$SAMPLER_PID" ] && kill -TERM "$SAMPLER_PID" 2>/dev/null && wait "$SAMPLER_PID" 2>/dev/null
    SAMPLER_PID=""
}

postgres_pid() {
    local dir
    dir=$("${PSQL[@]}" -At -c "SHOW data_directory" 2>/dev/null) || return 1
    sudo -n head -1 "$dir/postmaster.pid" 2>/dev/null || head -1 "$dir/postmaster.pid" 2>/dev/null
}

# One JSON line per measurement; lib/report.py parses the raw logs.
record() { # key=value ... (values are JSON-escaped strings)
    python3 - "$OUT/runs.jsonl" "$@" <<'EOF'
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
row = {}
for p in pairs:
    k, _, v = p.partition("=")
    row[k] = int(v) if v.isdigit() else v
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
EOF
}

rotate() { # <round> <list...>: the list rotated by round
    local r=$1; shift
    local arr=("$@") n=$#
    local i
    for ((i = 0; i < n; i++)); do printf '%s ' "${arr[$(((i + r) % n))]}"; done
}

# ---- environment -----------------------------------------------------------

log "run $RUN_ID -> $OUT"
log "cpus: server=$SERVER_CPUS ($WORKERS) loadgen=$LOADGEN_CPUS ($LOADGEN_THREADS) db=${DB_CPUS:-unpinned}"
python3 - "$OUT/env.json" <<EOF
import json, os, platform, subprocess, sys
def sh(c):
    try:
        return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=30).stdout.strip() or \
               subprocess.run(c, shell=True, capture_output=True, text=True, timeout=30).stderr.strip()
    except Exception as e:
        return f"error: {e}"
cpu = sh("lscpu | grep -E 'Model name|Socket|Thread|Core|NUMA node\\\\(s\\\\)|MHz' | sed 's/  */ /g'")
env = {
  "run_id": "$RUN_ID", "git_sha": sh("git -C $ROOT rev-parse HEAD"), "git_dirty": bool(sh("git -C $ROOT status --porcelain")),
  "kernel": platform.release(), "os": sh(". /etc/os-release && echo \$PRETTY_NAME"), "nproc": $NCPU,
  "memory": sh("free -h | awk '/^Mem:/{print \$2}'"), "cpu": cpu, "virtualization": sh("systemd-detect-virt 2>/dev/null"),
  "governor": sh("cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null"),
  "config": {"quick": "$QUICK", "tiers": "$TIERS", "langs": "$LANGS", "rounds": $ROUNDS,
             "server_cpus": "$SERVER_CPUS", "loadgen_cpus": "$LOADGEN_CPUS", "db_cpus": "${DB_CPUS:-}",
             "workers": $WORKERS, "users": $USERS, "orders": $ORDERS, "batch_rows": $BATCH_ROWS,
             "batch_users": $BATCH_USERS, "http_dur": "$HTTP_DUR", "http_conns": "$HTTP_CONNS",
             "api_dur": "$API_DUR", "api_conns": "$API_CONNS", "api_rates": "$API_RATES",
             "api_scenarios": "$API_SCENARIOS", "warmup": "$WARMUP", "db_pool_total": $DB_POOL_TOTAL,
             "cc_tasks": $CC_TASKS, "cc_work": $CC_WORK, "cc_alloc": $CC_ALLOC},
  "toolchains": {t: sh(c) for t, c in {
      "cc": "cc --version | head -1", "go": "go version", "rustc": "rustc --version", "cargo": "cargo --version",
      "dotnet": "dotnet --version", "java": "java -version 2>&1 | head -1", "mvn": "mvn -v | head -1",
      "python": "python3 --version", "bun": "bun --version", "node": "node --version",
      "postgres": "psql '$DATABASE_URL' -At -c 'select version()'", "wrk": "wrk -v 2>&1 | head -1",
      "wrk2": "wrk2 -v 2>&1 | head -1"}.items()},
}
json.dump(env, open(sys.argv[1], "w"), indent=2)
EOF

# ---- build -----------------------------------------------------------------

log "building: $LANGS"
BUILT=""
echo "{}" >"$OUT/builds.json"
for lang in $LANGS; do
    t0=$(date +%s%N)
    if build_lang "$lang" >"$OUT/raw/build-$lang.log" 2>&1; then
        ok=True; BUILT="$BUILT $lang"
    else
        ok=False; log "BUILD FAILED: $lang (see raw/build-$lang.log)"
    fi
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    python3 -c "import json; d=json.load(open('$OUT/builds.json')); d['$lang']={'ok':$ok,'seconds':round($ms/1000,1),'log':'raw/build-$lang.log'}; json.dump(d,open('$OUT/builds.json','w'),indent=2)"
done
LANGS=$(echo $BUILT)
log "built: $LANGS"

# ---- data --------------------------------------------------------------------

QUOTE_DIR="$DATA/quotes"
export QUOTE_DIR
[ -f "$QUOTE_DIR/quote_7.json" ] || python3 bench/suite/lib/gen_quote.py "$QUOTE_DIR" 8 2000

if has_tier heavy; then
    seeded=$("${PSQL[@]}" -At -c "SELECT string_agg(k || '=' || v, ',' ORDER BY k) FROM bench_meta" 2>/dev/null || true)
    if [ "$seeded" != "orders=$ORDERS,users=$USERS" ]; then
        log "seeding database: users=$USERS orders=$ORDERS (this takes a while at full scale)"
        "${PSQL[@]}" -f bench/suite/db/schema.sql >>"$LOG" 2>&1 &&
        "${PSQL[@]}" -v users="$USERS" -v orders="$ORDERS" -f bench/suite/db/seed.sql >>"$LOG" 2>&1 ||
            { log "seeding failed"; exit 1; }
    fi
    cc -O2 -o "$BIN/gen_batch" bench/suite/data/gen_batch.c
    BATCH_FILE="$DATA/batch_${BATCH_ROWS}_${BATCH_USERS}.csv"
    if [ ! -s "$BATCH_FILE" ]; then
        log "generating $BATCH_FILE"
        "$BIN/gen_batch" "$BATCH_FILE" "$BATCH_ROWS" "$BATCH_USERS" || { log "generation failed"; exit 1; }
    fi
    CHECK_FILE="$DATA/batch_check.csv"
    [ -s "$CHECK_FILE" ] || "$BIN/gen_batch" "$CHECK_FILE" 1000000 50000
    [ -s "$CHECK_FILE.ref" ] || python3 bench/suite/lib/batch_reference.py "$CHECK_FILE" >"$CHECK_FILE.ref"
fi

# ---- correctness gates ---------------------------------------------------------

declare -A PASS_API PASS_BATCH
echo "{}" >"$OUT/correctness.json"
set_correct() { # <workload> <lang> <status> <detail>
    python3 -c "import json; d=json.load(open('$OUT/correctness.json')); d.setdefault('$1',{})['$2']={'status':'$3','detail':'''$4'''}; json.dump(d,open('$OUT/correctness.json','w'),indent=2)"
}

if has_tier heavy; then
    for lang in $LANGS; do
        log "conformance api/$lang"
        "${PSQL[@]}" -f bench/suite/db/reset.sql >/dev/null 2>&1
        export PORT=18400
        start_server "$SERVER_CPUS" "$OUT/raw/conformance-api-$lang.server.log" "$(cmd api "$lang")"
        if wait_http "http://127.0.0.1:$PORT/health" 120 &&
           python3 bench/suite/lib/conformance.py "http://127.0.0.1:$PORT" "$QUOTE_DIR" >"$OUT/raw/conformance-api-$lang.log" 2>&1; then
            PASS_API[$lang]=1; set_correct api "$lang" pass ""
        else
            log "CONFORMANCE FAILED: api/$lang (see raw/conformance-api-$lang.log)"
            set_correct api "$lang" fail "raw/conformance-api-$lang.log"
        fi
        stop_server

        log "correctness batch/$lang"
        if taskset -c "$SERVER_CPUS" $(cmd batch "$lang") "$CHECK_FILE" >"$OUT/raw/check-batch-$lang.out" 2>"$OUT/raw/check-batch-$lang.err" &&
           cmp -s "$OUT/raw/check-batch-$lang.out" "$CHECK_FILE.ref"; then
            PASS_BATCH[$lang]=1; set_correct batch "$lang" pass ""
        else
            log "CORRECTNESS FAILED: batch/$lang"
            set_correct batch "$lang" fail "raw/check-batch-$lang.out"
        fi
    done
    "${PSQL[@]}" -f bench/suite/db/reset.sql >/dev/null 2>&1
fi

# ---- light: http-static ---------------------------------------------------------

if has_tier light; then
    for round in $(seq 1 "$ROUNDS"); do
        for lang in $(rotate "$round" $LANGS); do
            export HTTP_PORT=18300
            dir="$OUT/raw/light/http/$lang/round$round"; mkdir -p "$dir"
            start_server "$SERVER_CPUS" "$dir/server.log" "$(cmd http "$lang")"
            if ! wait_port "$HTTP_PORT" 60; then
                log "http/$lang did not start"; stop_server; continue
            fi
            for conns in $HTTP_CONNS; do
                log "light http $lang round $round c=$conns"
                sample_start "$SERVER_PID" "$dir/c$conns.sample.json"
                taskset -c "$LOADGEN_CPUS" wrk -t"$LOADGEN_THREADS" -c"$conns" -d"$HTTP_DUR" --latency \
                    "http://127.0.0.1:$HTTP_PORT/" >"$dir/c$conns.wrk.txt" 2>&1
                sample_stop
                record tier=light workload=http scenario=static lang="$lang" round="$round" \
                       connections="$conns" tool=wrk log="${dir#$OUT/}/c$conns.wrk.txt" \
                       sample="${dir#$OUT/}/c$conns.sample.json"
            done
            stop_server
        done
    done

    # ---- light: compute ----
    for round in $(seq 1 "$ROUNDS"); do
        for lang in $(rotate "$round" $LANGS); do
            dir="$OUT/raw/light/compute/$lang/round$round"; mkdir -p "$dir"
            log "light compute $lang round $round"
            setsid taskset -c "$SERVER_CPUS" bash -c "exec $(cmd compute "$lang")" >"$dir/out.txt" 2>"$dir/err.txt" &
            SERVER_PID=$!
            sample_start "$SERVER_PID" "$dir/sample.json"
            wait "$SERVER_PID"; code=$?
            SERVER_PID=""
            sample_stop
            record tier=light workload=compute scenario=compute lang="$lang" round="$round" exit="$code" \
                   log="${dir#$OUT/}/out.txt" sample="${dir#$OUT/}/sample.json"
        done
    done
fi

# ---- heavy: api ----------------------------------------------------------------------

if has_tier heavy; then
    PG_PID=$(postgres_pid || true)
    for round in $(seq 1 "$ROUNDS"); do
        for lang in $(rotate "$round" $LANGS); do
            [ -n "${PASS_API[$lang]:-}" ] || { log "skip api/$lang: failed conformance"; continue; }
            export PORT=18401
            dir="$OUT/raw/heavy/api/$lang/round$round"; mkdir -p "$dir"
            "${PSQL[@]}" -f bench/suite/db/reset.sql >/dev/null 2>&1
            start_server "$SERVER_CPUS" "$dir/server.log" "$(cmd api "$lang")"
            if ! wait_http "http://127.0.0.1:$PORT/health" 120; then
                log "api/$lang did not start"; stop_server; continue
            fi
            log "heavy api $lang round $round warm-up $WARMUP"
            taskset -c "$LOADGEN_CPUS" wrk -t"$LOADGEN_THREADS" -c64 -d"$WARMUP" -s bench/suite/lib/mix.lua \
                "http://127.0.0.1:$PORT" >"$dir/warmup.txt" 2>&1
            for scenario in $API_SCENARIOS; do
                for conns in $API_CONNS; do
                    log "heavy api $lang round $round $scenario c=$conns"
                    sample_start "$SERVER_PID" "$dir/$scenario-c$conns.sample.json"
                    [ -n "$PG_PID" ] && { python3 bench/suite/lib/sampler.py "$PG_PID" "$dir/$scenario-c$conns.db.json" 0.5 & DB_SAMPLER=$!; }
                    taskset -c "$LOADGEN_CPUS" wrk -t"$LOADGEN_THREADS" -c"$conns" -d"$API_DUR" --latency --timeout 10s \
                        -s "bench/suite/lib/$scenario.lua" "http://127.0.0.1:$PORT" >"$dir/$scenario-c$conns.wrk.txt" 2>&1
                    sample_stop
                    [ -n "$PG_PID" ] && { kill -TERM "$DB_SAMPLER" 2>/dev/null; wait "$DB_SAMPLER" 2>/dev/null; }
                    record tier=heavy workload=api scenario="$scenario" lang="$lang" round="$round" \
                           connections="$conns" tool=wrk log="${dir#$OUT/}/$scenario-c$conns.wrk.txt" \
                           sample="${dir#$OUT/}/$scenario-c$conns.sample.json" db_sample="${dir#$OUT/}/$scenario-c$conns.db.json"
                done
            done
            for rate in $API_RATES; do
                log "heavy api $lang round $round mix fixed rate $rate/s"
                sample_start "$SERVER_PID" "$dir/mix-r$rate.sample.json"
                taskset -c "$LOADGEN_CPUS" wrk2 -t"$LOADGEN_THREADS" -c256 -d"$API_DUR" -R"$rate" --latency --timeout 10s \
                    -s bench/suite/lib/mix.lua "http://127.0.0.1:$PORT" >"$dir/mix-r$rate.wrk2.txt" 2>&1
                sample_stop
                record tier=heavy workload=api scenario=mix lang="$lang" round="$round" rate="$rate" \
                       connections=256 tool=wrk2 log="${dir#$OUT/}/mix-r$rate.wrk2.txt" \
                       sample="${dir#$OUT/}/mix-r$rate.sample.json"
            done
            stop_server
        done
    done

    # ---- heavy: batch ----
    log "warming the page cache with $BATCH_FILE"
    cat "$BATCH_FILE" >/dev/null
    for round in $(seq 1 "$ROUNDS"); do
        for lang in $(rotate "$round" $LANGS); do
            [ -n "${PASS_BATCH[$lang]:-}" ] || { log "skip batch/$lang: failed correctness"; continue; }
            dir="$OUT/raw/heavy/batch/$lang/round$round"; mkdir -p "$dir"
            log "heavy batch $lang round $round"
            t0=$(date +%s%N)
            setsid taskset -c "$SERVER_CPUS" bash -c "exec $(cmd batch "$lang") '$BATCH_FILE'" >"$dir/out.txt" 2>"$dir/err.txt" &
            SERVER_PID=$!
            sample_start "$SERVER_PID" "$dir/sample.json"
            wait "$SERVER_PID"; code=$?
            wall_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
            SERVER_PID=""
            sample_stop
            sha=$(sha256sum "$dir/out.txt" | cut -d' ' -f1)
            record tier=heavy workload=batch scenario=batch lang="$lang" round="$round" exit="$code" \
                   wall_ms="$wall_ms" output_sha256="$sha" log="${dir#$OUT/}/out.txt" sample="${dir#$OUT/}/sample.json"
        done
    done
fi

log "measurements done; writing results.json and summary.md"
python3 bench/suite/lib/report.py "$OUT" | tee -a "$LOG"
log "done: $OUT"
