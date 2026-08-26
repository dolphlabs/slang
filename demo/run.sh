#!/bin/sh
# Builds the demo's tiny C fixture (lib.c) into a static archive,
# points LIBRARY_PATH at it so 'link "slangarcade";' in main.sl
# resolves, then compiles and runs the server. Mirrors exactly how
# tests/run_tests.sh links tests/ffi/lib.c.
set -eu
cd "$(dirname "$0")"

build_dir="$(mktemp -d 2>/dev/null || echo /tmp/slangarcade_build)"
mkdir -p "$build_dir"

cc -std=c11 -O2 -c lib.c -o "$build_dir/lib.o"
ar rcs "$build_dir/libslangarcade.a" "$build_dir/lib.o"

LIBRARY_PATH="$build_dir${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LIBRARY_PATH

if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "generating a self-signed cert for the TLS listener (one-time)..." >&2
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout key.pem -out cert.pem -days 3650 \
        -subj "/CN=localhost" >/dev/null 2>&1
fi

SLANGC="${SLANGC:-../slangc}"
if [ ! -x "$SLANGC" ]; then
    echo "slangc not found at $SLANGC -- build it first (cd .. && make) or set SLANGC=/path/to/slangc" >&2
    exit 1
fi

exec "$SLANGC" main.sl --run
