#!/bin/sh
# Orchestrates the full stress-test matrix against the slang Arcade
# demo: builds the server, runs a series of loadgen phases against it
# (per-endpoint characterization, thread-multiplication, mixed
# workload, a soak test, and one CPU profile capture), and leaves
# results/*.json + results/*.csv + results/server.log behind for the
# report. See demo/README.md's "Stress test" section for how to read
# the output.
set -u
cd "$(dirname "$0")"
HARNESS_DIR="$(pwd)"
DEMO_DIR="$(cd .. && pwd)"
RESULTS_DIR="$HARNESS_DIR/results"
mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.csv

PORT=8095
TLS_PORT=8096
BASE_URL="http://localhost:$PORT"
BIN="/tmp/arcade_stress_run"

echo "=== building demo server ==="
build_dir=$(mktemp -d)
cc -std=c11 -O2 -g -c "$DEMO_DIR/lib.c" -o "$build_dir/lib.o" || exit 1
ar rcs "$build_dir/libslangarcade.a" "$build_dir/lib.o" || exit 1
( cd "$DEMO_DIR" && LIBRARY_PATH="$build_dir" "$DEMO_DIR/../slangc" main.sl -o "$BIN" ) || exit 1
echo "built $BIN"

SERVER_PID=""

start_server() {
    LIBRARY_PATH="$build_dir" PORT=$PORT TLS_PORT=$TLS_PORT "$BIN" > "$RESULTS_DIR/server.log" 2>&1 &
    SERVER_PID=$!
    echo "server pid=$SERVER_PID"
    i=0
    while [ $i -lt 30 ]; do
        if curl -s -o /dev/null "$BASE_URL/api/stress/ping"; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "server did not come up in time"
    return 1
}

stop_server() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null
        i=0
        while kill -0 "$SERVER_PID" 2>/dev/null && [ $i -lt 50 ]; do
            sleep 0.2
            i=$((i + 1))
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "server did not exit gracefully, sending SIGKILL"
            kill -9 "$SERVER_PID" 2>/dev/null
        fi
    fi
}

# run_phase <scenario> <concurrency> <duration_s> <rate|0>
run_phase() {
    scenario="$1"
    conc="$2"
    dur="$3"
    rate="$4"
    label="${scenario}_c${conc}"
    stopfile="/tmp/monitor_${label}.stop"
    rm -f "$stopfile"

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "!! server is dead before phase $label, restarting"
        start_server || { echo "!! could not restart server, aborting"; exit 1; }
    fi

    "$HARNESS_DIR/monitor.sh" "$SERVER_PID" "$RESULTS_DIR/${label}.csv" "$stopfile" &
    mon_pid=$!

    "$HARNESS_DIR/loadgen" \
        -config "$HARNESS_DIR/scenarios/${scenario}.json" \
        -concurrency "$conc" -duration "${dur}s" -rate "$rate" \
        -label "$label" -out "$RESULTS_DIR/${label}.json"

    touch "$stopfile"
    wait "$mon_pid" 2>/dev/null
    sleep 1
}

echo "=== starting server ==="
start_server || exit 1
sleep 1

echo "=== Phase A: per-endpoint characterization ==="
for scenario in ping cpu alloc json sleep chan counter; do
    for conc in 25 100 300 600; do
        run_phase "$scenario" "$conc" 8 0
    done
done

echo "=== Phase B: thread-multiplication (fanout, workers=8) ==="
for conc in 10 40 80; do
    run_phase "fanout" "$conc" 8 0
done

echo "=== Phase C: mixed realistic workload, escalating ==="
for conc in 50 200 500 900; do
    run_phase "mixed" "$conc" 15 0
done

echo "=== Phase D: deliberate breaking-point probe (sleep endpoint holds threads open) ==="
for conc in 1200 2000; do
    run_phase "sleep" "$conc" 10 0
done

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "!! server died during Phase D (thread exhaustion) -- this is itself a finding, restarting for remaining phases"
    start_server || exit 1
    sleep 1
fi

echo "=== Phase E: soak test (60s sustained mixed load, watch RSS trend) ==="
stopfile="/tmp/monitor_soak.stop"
rm -f "$stopfile"
"$HARNESS_DIR/monitor.sh" "$SERVER_PID" "$RESULTS_DIR/soak.csv" "$stopfile" &
mon_pid=$!
"$HARNESS_DIR/loadgen" -config "$HARNESS_DIR/scenarios/mixed.json" \
    -concurrency 250 -duration 60s -rate 0 -label soak -out "$RESULTS_DIR/soak.json"
touch "$stopfile"
wait "$mon_pid" 2>/dev/null

echo "=== Phase F: CPU profile capture (sample during a mixed burst) ==="
if kill -0 "$SERVER_PID" 2>/dev/null; then
    sample "$SERVER_PID" 8 -file "$RESULTS_DIR/profile.txt" >/dev/null 2>&1 &
    sample_pid=$!
    "$HARNESS_DIR/loadgen" -config "$HARNESS_DIR/scenarios/mixed.json" \
        -concurrency 300 -duration 10s -rate 0 -label profile_burst -out "$RESULTS_DIR/profile_burst.json"
    wait "$sample_pid" 2>/dev/null
fi

echo "=== stopping server ==="
stop_server
cp "$RESULTS_DIR/server.log" "$RESULTS_DIR/server_final.log" 2>/dev/null

echo "=== all phases complete, results in $RESULTS_DIR ==="
ls -la "$RESULTS_DIR"
