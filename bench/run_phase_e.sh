#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=/tmp/slang_phase_e
mkdir -p "$OUT"

{
    echo "=== machine ==="
    date -u
    uname -a
    echo "nproc=$(nproc)"
    lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket|MHz|Vendor'
    free -h
    echo "cc=$(cc --version | head -1)"
    echo "gcc=$(gcc --version | head -1)"
    echo "go=$(go version)"
    echo "rustc=$(rustc --version)"
    echo "cargo=$(cargo --version)"
    echo "wrk=$(wrk --version 2>&1 | head -1)"
    echo "git=$(git rev-parse --short HEAD) $(git branch --show-current)"
    echo
    echo "=== compute ==="
    CC_TASKS="${CC_TASKS:-200}" CC_WORK="${CC_WORK:-8000}" CC_ALLOC="${CC_ALLOC:-50}" \
        CC_ROUNDS="${CC_ROUNDS:-3}" ./bench/run_compute.sh
    echo
    echo "=== http ==="
    HTTP_ROUNDS="${HTTP_ROUNDS:-3}" HTTP_DUR="${HTTP_DUR:-10s}" ./bench/run_http.sh
} 2>&1 | tee "$OUT/phase_e.log"

echo "wrote $OUT/phase_e.log"
