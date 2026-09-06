#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

export PATH="${HOME}/.local/bin:${HOME}/.dotnet:${PATH:-/usr/bin}"
export DOTNET_ROOT="${DOTNET_ROOT:-${HOME}/.dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

OUT=/tmp/slang_phase_e
mkdir -p "$OUT"

{
    echo "=== machine ==="
    date -u
    uname -a
    echo "nproc=$(nproc)"
    lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket|MHz|Vendor' || true
    free -h
    echo "cc=$(cc --version | head -1)"
    echo "gcc=$(gcc --version | head -1)"
    echo "go=$(go version 2>/dev/null || echo missing)"
    echo "rustc=$(rustc --version 2>/dev/null || echo missing)"
    echo "cargo=$(cargo --version 2>/dev/null || echo missing)"
    echo "javac=$(javac -version 2>&1 || echo missing)"
    echo "java=$(java -version 2>&1 | head -1 || echo missing)"
    echo "zig=$(zig version 2>/dev/null || echo missing)"
    echo "dotnet=$(dotnet --version 2>/dev/null || echo missing)"
    echo "wrk=$(wrk --version 2>&1 | head -1 || echo missing)"
    echo "git=$(git rev-parse HEAD) $(git branch --show-current)"
    echo
    echo "=== compute ==="
    CC_TASKS="${CC_TASKS:-200}" CC_WORK="${CC_WORK:-8000}" CC_ALLOC="${CC_ALLOC:-50}" \
        CC_ROUNDS="${CC_ROUNDS:-3}" ./bench/run_compute.sh
    echo
    echo "=== http ==="
    HTTP_ROUNDS="${HTTP_ROUNDS:-3}" HTTP_DUR="${HTTP_DUR:-10s}" ./bench/run_http.sh
} 2>&1 | tee "$OUT/phase_e.log"

echo "wrote $OUT/phase_e.log"
