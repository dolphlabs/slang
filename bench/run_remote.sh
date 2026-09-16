#!/bin/sh
# Run the cross-language benchmark suite on a remote Linux host and bring
# the results back.
#
#   bench/run_remote.sh --host 1.2.3.4 --user ubuntu --key ~/.ssh/x.pem
#
# Options:
#   --host H     hostname or IP (required)
#   --user U     ssh user (default: ubuntu)
#   --key K      identity file (default: ssh's own resolution)
#   --dir D      remote working directory (default: ~/slang-bench)
#   --rounds N   rounds per benchmark (default: 3)
#   --dur D      wrk duration per round (default: 10s)
#   --preflight  inspect the host and stop -- no upload, no build, no run
#   --yes        skip the confirmation prompt
#
# WHY THE PREFLIGHT EXISTS
#
# This suite saturates every core for several minutes and binds ports.
# On a box that is serving anything, that is an outage, not a benchmark.
# So the default is to look first: load average, listening ports, and
# whether any of the toolchains are already present. Read that output
# before answering the prompt.
#
# WHAT MAKES A RESULT COMPARABLE
#
# bench/RESULTS.md records the machine, every toolchain version, and the
# commit measured, because a number without those is not a measurement.
# This script collects the same set. A VPS is NOT comparable to the
# numbers already in RESULTS.md -- different CPU, different kernel,
# different neighbours -- so its output belongs beside them as its own
# run, never merged into them.

set -eu

HOST=""; USER_NAME="ubuntu"; KEY=""; RDIR="slang-bench"
ROUNDS=3; DUR=10s; PREFLIGHT=0; ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST=$2; shift 2 ;;
        --user) USER_NAME=$2; shift 2 ;;
        --key) KEY=$2; shift 2 ;;
        --dir) RDIR=$2; shift 2 ;;
        --rounds) ROUNDS=$2; shift 2 ;;
        --dur) DUR=$2; shift 2 ;;
        --preflight) PREFLIGHT=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$HOST" ] || { echo "--host is required (see --help)" >&2; exit 2; }

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
[ -n "$KEY" ] && SSH_OPTS="$SSH_OPTS -i $KEY"
TARGET="${USER_NAME}@${HOST}"

r() { ssh $SSH_OPTS "$TARGET" "$@"; }

echo "=== preflight: $TARGET ==="
r 'set -eu
   echo "uname:   $(uname -a)"
   echo "nproc:   $(nproc)"
   echo "memory:  $(free -h 2>/dev/null | awk "/^Mem:/{print \$2}")"
   echo "load:    $(cat /proc/loadavg)"
   echo "uptime:  $(uptime -p 2>/dev/null || true)"
   echo
   echo "-- listening ports (a busy box is not a benchmark host) --"
   (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | head -20
   echo
   echo "-- toolchains --"
   for t in cc gcc clang go cargo rustc javac java zig dotnet wrk git make python3; do
     v=$(command -v "$t" >/dev/null 2>&1 && "$t" --version 2>&1 | head -1 || echo MISSING)
     printf "%-8s %s\n" "$t" "$v"
   done'

[ "$PREFLIGHT" -eq 1 ] && { echo; echo "preflight only; nothing uploaded or run."; exit 0; }

if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    echo "This will saturate every core on $HOST for several minutes and"
    echo "bind local ports. Do not run it on a host serving anything."
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

echo
echo "=== uploading working tree -> $TARGET:$RDIR ==="
r "mkdir -p '$RDIR'"
RSYNC_SSH="ssh $SSH_OPTS"
rsync -az --delete \
    --exclude '.git' --exclude 'docs/' --exclude 'slangc' \
    --exclude '*.gen.c' --exclude 'stress_test/results*' \
    -e "$RSYNC_SSH" \
    "$(cd "$(dirname "$0")/.." && pwd)/" "$TARGET:$RDIR/"

echo
echo "=== building slangc ==="
r "cd '$RDIR' && make -s slangc && ./slangc --version 2>/dev/null || true"

echo
echo "=== running the suite (rounds=$ROUNDS dur=$DUR) ==="
echo "    this takes a while; output streams below"
r "cd '$RDIR' && HTTP_ROUNDS=$ROUNDS CC_ROUNDS=$ROUNDS HTTP_DUR=$DUR \
   sh bench/run_phase_e.sh"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOCAL_OUT="bench/remote/$STAMP"
mkdir -p "$LOCAL_OUT"
echo
echo "=== collecting -> $LOCAL_OUT ==="
scp $SSH_OPTS "$TARGET:/tmp/slang_phase_e/phase_e.log" "$LOCAL_OUT/" 2>/dev/null \
    || echo "  (no phase_e.log -- check the run output above)"
r "cd '$RDIR' && git rev-parse HEAD 2>/dev/null || echo unknown" \
    > "$LOCAL_OUT/commit.txt"

echo
echo "done. raw log: $LOCAL_OUT/"
echo "Record it in bench/RESULTS.md as its OWN run -- a different machine"
echo "is a different measurement, not a new data point in an existing one."
