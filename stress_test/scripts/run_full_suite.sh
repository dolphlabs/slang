#!/bin/sh
# Slang comprehensive stress suite -- server-side (HTTP, via the same
# Arcade demo server Tier 9-11 verification already relies on) AND raw
# network (a real TCP echo server, stress_test/programs/tcp_echo) AND
# pure in-process concurrency (stress_test/programs/concurrent_compute,
# no network at all -- isolates the M:N scheduler/GC from net.*'s own
# cost). Exact request-count scaling (10k through 100k, via loadgen's
# new -requests flag) is the headline dimension the demo harness didn't
# cover (it's duration-based); concurrency scaling, per-endpoint
# characterization, a breaking-point probe, a soak test, and CPU
# profile captures round it out. Every phase samples RSS/%CPU/thread
# count of the process under test (monitor.sh) so throughput and
# latency numbers can be read against real resource cost, not just
# assumed.
#
# Writes results/*.json (loadgen/tcp_loadgen output), results/*.csv
# (RSS/CPU samples), results/profile_*.txt (CPU profiles), and
# results/compute_*.txt (concurrent_compute's own stdout) -- see
# reports/stress_report.html for the analysis built from these.
set -u
cd "$(dirname "$0")/.." || exit 1
ST_DIR="$(pwd)"
ROOT_DIR="$(cd .. && pwd)"
RESULTS_DIR="$ST_DIR/results"
mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.csv "$RESULTS_DIR"/*.txt

SLANGC="$ROOT_DIR/slangc"
# Matches the base_url baked into demo/stress_harness/scenarios/*.json
# (reused directly below, not duplicated) -- must agree with those
# files' own hardcoded port, not a locally-chosen one.
HTTP_PORT=8095
TCP_PORT=9195
HTTP_BASE="http://localhost:$HTTP_PORT"
HTTP_BIN="/tmp/stress_arcade_run"
TCP_BIN="/tmp/stress_tcp_echo_run"
CC_BIN="/tmp/stress_concurrent_compute_run"

echo "=== building slangc ==="
( cd "$ROOT_DIR" && make -s slangc ) || exit 1

echo "=== building demo Arcade server (HTTP stress target) ==="
build_dir=$(mktemp -d)
cc -std=c11 -O2 -g -c "$ROOT_DIR/demo/lib.c" -o "$build_dir/lib.o" || exit 1
ar rcs "$build_dir/libslangarcade.a" "$build_dir/lib.o" || exit 1
( cd "$ROOT_DIR/demo" && LIBRARY_PATH="$build_dir" "$SLANGC" main.sl -o "$HTTP_BIN" ) || exit 1

echo "=== building tcp_echo server ==="
"$SLANGC" "$ST_DIR/programs/tcp_echo/main.sl" -o "$TCP_BIN" || exit 1

echo "=== building concurrent_compute ==="
"$SLANGC" "$ST_DIR/programs/concurrent_compute/main.sl" -o "$CC_BIN" || exit 1

echo "=== building load generators ==="
( cd "$ROOT_DIR/demo/stress_harness" && go build -o loadgen loadgen.go ) || exit 1
LOADGEN="$ROOT_DIR/demo/stress_harness/loadgen"
( cd "$ST_DIR/scripts" && go build -o tcp_loadgen tcp_loadgen.go ) || exit 1
TCP_LOADGEN="$ST_DIR/scripts/tcp_loadgen"

HTTP_PID=""
TCP_PID=""

start_http() {
    LIBRARY_PATH="$build_dir" PORT=$HTTP_PORT "$HTTP_BIN" > "$RESULTS_DIR/http_server.log" 2>&1 &
    HTTP_PID=$!
    i=0
    while [ $i -lt 30 ]; do
        curl -s -o /dev/null "$HTTP_BASE/api/stress/ping" && return 0
        sleep 0.2
        i=$((i + 1))
    done
    echo "!! http server did not come up"
    return 1
}

stop_http() {
    [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null || return 0
    kill -TERM "$HTTP_PID" 2>/dev/null
    i=0
    while kill -0 "$HTTP_PID" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    kill -0 "$HTTP_PID" 2>/dev/null && kill -9 "$HTTP_PID" 2>/dev/null
}

start_tcp() {
    TCP_ECHO_PORT=$TCP_PORT TCP_ECHO_WORKERS=128 "$TCP_BIN" > "$RESULTS_DIR/tcp_server.log" 2>&1 &
    TCP_PID=$!
    i=0
    while [ $i -lt 30 ]; do
        nc -z 127.0.0.1 $TCP_PORT 2>/dev/null && return 0
        sleep 0.2
        i=$((i + 1))
    done
    echo "!! tcp echo server did not come up"
    return 1
}

stop_tcp() {
    [ -n "$TCP_PID" ] && kill -0 "$TCP_PID" 2>/dev/null || return 0
    kill -TERM "$TCP_PID" 2>/dev/null
    i=0
    while kill -0 "$TCP_PID" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    kill -0 "$TCP_PID" 2>/dev/null && kill -9 "$TCP_PID" 2>/dev/null
}

# run_http_phase <label> <scenario.json> <concurrency> <requests> <duration_cap>
run_http_phase() {
    label="$1"; scenario="$2"; conc="$3"; reqs="$4"; cap="$5"
    stopfile="/tmp/st_monitor_${label}.stop"
    rm -f "$stopfile"
    kill -0 "$HTTP_PID" 2>/dev/null || { echo "!! http server dead before $label, restarting"; start_http || exit 1; }
    "$ST_DIR/scripts/monitor.sh" "$HTTP_PID" "$RESULTS_DIR/${label}.csv" "$stopfile" &
    mon_pid=$!
    "$LOADGEN" -config "$ROOT_DIR/demo/stress_harness/scenarios/${scenario}.json" \
        -concurrency "$conc" -requests "$reqs" -duration "${cap}s" \
        -label "$label" -out "$RESULTS_DIR/${label}.json"
    touch "$stopfile"
    wait "$mon_pid" 2>/dev/null
    sleep 0.5
}

# run_tcp_phase <label> <concurrency> <requests> <duration_cap> [persistent_flag]
# persistent_flag: pass "-persistent" to keep one connection per worker
# open across many echo round-trips (the scaling-safe mode -- see
# tcp_loadgen.go's own header comment for why the default,
# connect-per-request mode hits macOS's ~16384-port ephemeral ceiling
# past roughly 10-15k sustained connects), or "" for connection-churn
# mode (real, but must stay well under that ceiling to give clean data).
run_tcp_phase() {
    label="$1"; conc="$2"; reqs="$3"; cap="$4"; pflag="${5:-}"
    stopfile="/tmp/st_monitor_${label}.stop"
    rm -f "$stopfile"
    kill -0 "$TCP_PID" 2>/dev/null || { echo "!! tcp server dead before $label, restarting"; start_tcp || exit 1; }
    "$ST_DIR/scripts/monitor.sh" "$TCP_PID" "$RESULTS_DIR/${label}.csv" "$stopfile" &
    mon_pid=$!
    "$TCP_LOADGEN" -addr "127.0.0.1:$TCP_PORT" -concurrency "$conc" -requests "$reqs" \
        -duration "${cap}s" $pflag -label "$label" -out "$RESULTS_DIR/${label}.json"
    touch "$stopfile"
    wait "$mon_pid" 2>/dev/null
    sleep 0.5
}

# run_compute_phase <label> <tasks> <work_n> <alloc_n>
run_compute_phase() {
    label="$1"; tasks="$2"; work_n="$3"; alloc_n="$4"
    stopfile="/tmp/st_monitor_${label}.stop"
    rm -f "$stopfile"
    ( CC_TASKS="$tasks" CC_WORK="$work_n" CC_ALLOC="$alloc_n" "$CC_BIN" > "$RESULTS_DIR/${label}.txt" 2>&1 ) &
    cc_pid=$!
    "$ST_DIR/scripts/monitor.sh" "$cc_pid" "$RESULTS_DIR/${label}.csv" "$stopfile" &
    mon_pid=$!
    wait "$cc_pid" 2>/dev/null
    touch "$stopfile"
    wait "$mon_pid" 2>/dev/null
}

echo "=== starting HTTP server ==="
start_http || exit 1
sleep 1

echo "=== Phase 1: HTTP request-count scaling (mixed workload, concurrency=200) ==="
for n in 10000 20000 30000 40000 50000 60000 70000 80000 90000 100000; do
    run_http_phase "http_count_${n}" mixed 200 "$n" 120
done

echo "=== Phase 2: HTTP concurrency scaling (mixed workload, 50000 requests) ==="
for c in 10 50 100 250 500 1000 2000; do
    run_http_phase "http_conc_${c}" mixed "$c" 50000 120
done

echo "=== Phase 3: HTTP per-endpoint characterization (concurrency=100) ==="
for scenario in ping json sleep chan counter; do
    run_http_phase "http_endpoint_${scenario}" "$scenario" 100 20000 120
done
for scenario in cpu alloc fanout; do
    run_http_phase "http_endpoint_${scenario}" "$scenario" 100 3000 180
done

echo "=== Phase 4: HTTP breaking-point probe (sleep endpoint) ==="
for c in 3000 5000; do
    run_http_phase "http_break_${c}" sleep "$c" 8000 90
done

echo "=== Phase 5: HTTP soak test (60s sustained mixed load, concurrency=250) ==="
stopfile="/tmp/st_monitor_http_soak.stop"
rm -f "$stopfile"
"$ST_DIR/scripts/monitor.sh" "$HTTP_PID" "$RESULTS_DIR/http_soak.csv" "$stopfile" &
mon_pid=$!
"$LOADGEN" -config "$ROOT_DIR/demo/stress_harness/scenarios/mixed.json" \
    -concurrency 250 -duration 60s -label http_soak -out "$RESULTS_DIR/http_soak.json"
touch "$stopfile"
wait "$mon_pid" 2>/dev/null

echo "=== Phase 6: HTTP CPU profile capture (sample during a mixed burst) ==="
if command -v sample >/dev/null 2>&1 && kill -0 "$HTTP_PID" 2>/dev/null; then
    sample "$HTTP_PID" 8 -file "$RESULTS_DIR/profile_http.txt" >/dev/null 2>&1 &
    sample_pid=$!
    "$LOADGEN" -config "$ROOT_DIR/demo/stress_harness/scenarios/mixed.json" \
        -concurrency 300 -duration 10s -label http_profile_burst -out "$RESULTS_DIR/http_profile_burst.json"
    wait "$sample_pid" 2>/dev/null
fi

echo "=== stopping HTTP server ==="
stop_http
cp "$RESULTS_DIR/http_server.log" "$RESULTS_DIR/http_server_final.log" 2>/dev/null

echo "=== starting TCP echo server ==="
start_tcp || exit 1
sleep 1

echo "=== Phase 7: TCP echo request-count scaling, persistent connections (concurrency=100) ==="
for n in 10000 20000 30000 40000 50000 60000 70000 80000 90000 100000; do
    run_tcp_phase "tcp_count_${n}" 100 "$n" 90 "-persistent"
done

echo "=== Phase 8: TCP echo concurrency scaling, persistent connections (50000 round-trips) ==="
for c in 10 50 100 250 500 1000; do
    run_tcp_phase "tcp_conc_${c}" "$c" 50000 90 "-persistent"
done

# Real, but deliberately bounded well under the ~16384-port ephemeral
# ceiling confirmed above -- a clean characterization of pure
# connect/accept/teardown cost (distinct from steady-state echo
# throughput, which Phases 7-8 measure), not a scaling curve.
echo "=== Phase 9: TCP echo connection-churn characterization (bounded, non-persistent) ==="
run_tcp_phase "tcp_churn_10000" 100 10000 60 ""

echo "=== Phase 10: TCP echo CPU profile capture (persistent, steady-state echo) ==="
if command -v sample >/dev/null 2>&1 && kill -0 "$TCP_PID" 2>/dev/null; then
    sample "$TCP_PID" 8 -file "$RESULTS_DIR/profile_tcp.txt" >/dev/null 2>&1 &
    sample_pid=$!
    "$TCP_LOADGEN" -addr "127.0.0.1:$TCP_PORT" -concurrency 300 -duration 10s -persistent \
        -label tcp_profile_burst -out "$RESULTS_DIR/tcp_profile_burst.json"
    wait "$sample_pid" 2>/dev/null
fi

echo "=== stopping TCP echo server ==="
stop_tcp
cp "$RESULTS_DIR/tcp_server.log" "$RESULTS_DIR/tcp_server_final.log" 2>/dev/null

# Phase 10's scale is deliberately NOT the same "up to 100k" as the
# request-count phases above: sl_task_submit allocates each task's
# growable stack (64KB to start) immediately at spawn time, and this
# program spawns every task before any of them can finish and free
# theirs -- at N=100000 that's 100000*64KB ~= 6.4GB of stack alone,
# alive simultaneously, on top of whatever else is running. Scaled
# instead to a max (20000 tasks ~= 1.25GB of stack) that's still a
# genuinely heavy, meaningful concurrent-task count -- real evidence
# of how many simultaneously-alive tasks this runtime carries -- without
# gambling a 16GB dev machine's stability on an unbounded memory spike.
echo "=== Phase 11: heavy concurrent-task stress (in-process, no network) ==="
for n in 1000 2500 5000 10000 15000 20000; do
    run_compute_phase "compute_${n}" "$n" 5000 50
done

echo "=== Phase 12: concurrent-compute CPU profile capture (10000 tasks) ==="
if command -v sample >/dev/null 2>&1; then
    ( CC_TASKS=10000 CC_WORK=5000 CC_ALLOC=50 "$CC_BIN" > "$RESULTS_DIR/compute_profile_run.txt" 2>&1 ) &
    cc_pid=$!
    sleep 0.3
    kill -0 "$cc_pid" 2>/dev/null && sample "$cc_pid" 12 -file "$RESULTS_DIR/profile_compute.txt" >/dev/null 2>&1
    wait "$cc_pid" 2>/dev/null
fi

echo "=== all phases complete, results in $RESULTS_DIR ==="
ls -la "$RESULTS_DIR"
