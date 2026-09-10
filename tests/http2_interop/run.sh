#!/bin/sh
# Interop against an INDEPENDENT HTTP/2 implementation.
#
# Every other check on this server has run against nghttp2's framing and
# HPACK -- curl uses nghttp2, and the HPACK fixtures were generated with
# it. Agreement between two things that share an implementation proves
# less than it looks like it does.
#
# Go's golang.org/x/net/http2 shares no ancestry with nghttp2. It is
# also strict: it validates the frame sequence, rejects a flow-control
# overrun as a connection error, and enforces HPACK rules itself, so a
# passing run is real evidence rather than mutual agreement.
#
# Not part of `make test`: it needs a Go toolchain and fetches a module.
# Run it by hand:  sh tests/http2_interop/run.sh
set -eu
cd "$(dirname "$0")/../.."

if ! command -v go >/dev/null 2>&1; then
    echo "SKIP: no go toolchain" >&2
    exit 0
fi

SLANGC="${SLANGC:-./slangc}"
if [ ! -x "$SLANGC" ]; then
    echo "slangc not found at $SLANGC -- run make first" >&2
    exit 1
fi

probe="${TMPDIR:-/tmp}/slang_h2probe"
mkdir -p "$probe"
cp tests/http2_interop/probe.go "$probe/main.go"
cd "$probe"
[ -f go.mod ] || go mod init h2probe >/dev/null 2>&1
go get golang.org/x/net/http2@latest >/dev/null 2>&1
go build -o h2probe . || { echo "probe build failed" >&2; exit 1; }
cd - >/dev/null

srv="${TMPDIR:-/tmp}/slang_h2_interop_srv"
"$SLANGC" tests/http2_interop/server.sl -o "$srv" >/dev/null 2>&1 || {
    echo "server build failed" >&2; exit 1; }

"$srv" &
srv_pid=$!
# shellcheck disable=SC2064
trap "kill $srv_pid 2>/dev/null || true" EXIT INT TERM

# Wait for the listener rather than sleeping a guessed amount.
i=0
while [ "$i" -lt 100 ]; do
    if nc -z 127.0.0.1 8123 2>/dev/null; then break; fi
    i=$((i + 1))
    sleep 0.1
done
if [ "$i" -ge 100 ]; then
    echo "server never came up" >&2
    exit 1
fi

"$probe/h2probe" 127.0.0.1:8123
