#!/bin/sh
# HTTP/2 against a REAL BROWSER.
#
# Browsers speak h2 only over TLS with ALPN, so this is the one client
# that exercises the whole stack the way the web actually does -- and it
# is a genuinely independent implementation, unrelated to both nghttp2
# (curl) and Go's x/net/http2.
#
# It checks three things:
#
#   1. the browser negotiated h2 and the page rendered
#   2. all six slow sub-resources completed on ONE connection
#   3. the server's log contains no errors. Browsers produce two
#      benign shapes that OpenSSL reports as faults: closing without
#      close_notify ("unexpected eof while reading"), and dropping a
#      preconnect mid-handshake ("shutdown while in init"). Both must
#      read as end-of-stream, or every real disconnect logs an alarming
#      error and buries the ones that matter.
#
#      The match here is on the LEVEL FIELD, not the substring "error":
#      an OpenSSL message contains that word, so a substring match fired
#      on benign INFO lines.
#
# Not part of `make test`: it needs Chrome. Run by hand:
#     sh tests/http2_browser/run.sh
#
# KNOWN FLAKE, roughly one run in ten: Chrome connects and negotiates
# h2 -- the server log proves it, and "server saw ALPN select h2"
# passes -- but the page never finishes rendering, so the DOM checks
# fail. The cause is on the browser side and is NOT understood. Raising
# --virtual-time-budget from 8000 to 20000 was tried and changed
# nothing, so it is not a cut-off; that flag is back at 8000.
#
# Read a failure accordingly: if "server saw ALPN select h2" passed and
# only the DOM checks failed, that is this flake, not a regression.
# Re-run before investigating. A real server regression fails the ALPN
# check too, or changes what the connection log says.
set -eu
cd "$(dirname "$0")/../.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
    if command -v google-chrome >/dev/null 2>&1; then
        CHROME=$(command -v google-chrome)
    elif command -v chromium >/dev/null 2>&1; then
        CHROME=$(command -v chromium)
    else
        echo "SKIP: no Chrome/Chromium found (set CHROME=/path/to/chrome)" >&2
        exit 0
    fi
fi

SLANGC="${SLANGC:-./slangc}"
if [ ! -x "$SLANGC" ]; then
    echo "slangc not found at $SLANGC -- run make first" >&2
    exit 1
fi

work="${TMPDIR:-/tmp}/slang_h2_browser"
mkdir -p "$work"

# A self-signed cert with a real subjectAltName. Chrome rejects
# CN-only certs outright, and --ignore-certificate-errors does not
# apply to every check, so the SAN is not optional even here.
if [ ! -f "$work/cert.pem" ] || [ ! -f "$work/key.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$work/key.pem" -out "$work/cert.pem" -days 825 \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1
fi

"$SLANGC" tests/http2_browser/server.sl -o "$work/server" >/dev/null 2>&1 || {
    echo "server build failed" >&2; exit 1; }

# The server reads cert.pem/key.pem from its working directory.
cd "$work"
./server > "$work/log" 2>&1 &
srv_pid=$!
# shellcheck disable=SC2064
trap "kill $srv_pid 2>/dev/null || true" EXIT INT TERM

i=0
while [ "$i" -lt 100 ]; do
    if nc -z 127.0.0.1 8443 2>/dev/null; then break; fi
    i=$((i + 1))
    sleep 0.1
done
if [ "$i" -ge 100 ]; then
    echo "FAIL server never came up" >&2
    cat "$work/log" >&2
    exit 1
fi

dom="$work/dom.html"
# A FRESH profile per run. Repeated launches against a shared default
# profile contend on its lock, and a Chrome that loses that race exits
# without connecting at all -- which showed up as one run in twenty
# reporting four server-shaped failures ("server never negotiated h2")
# for a server that was never contacted.
# Deliberately NOT passing --user-data-dir. Both a fresh profile per
# run and a reused private one made Chrome hang on launch here; the
# default profile is the only one that starts reliably. It does mean a
# rapid series of runs can occasionally lose a profile-lock race and
# exit without connecting -- which the SKIP below exists to report
# honestly rather than blame on the server.
"$CHROME" --headless --disable-gpu --no-sandbox \
    --ignore-certificate-errors --virtual-time-budget=8000 \
    --dump-dom https://localhost:8443/ > "$dom" 2>/dev/null || true

sleep 1
fails=0

# Distinguish "the browser never ran" from "the server misbehaved".
# Without this the cascade of empty-DOM failures accuses the server of
# something the browser never gave it a chance to do.
if [ ! -s "$dom" ] && ! grep -q "ALPN negotiated h2" "$work/log"; then
    echo "SKIP: Chrome produced no output and never reached the server" >&2
    echo "      (launch failure, not a server fault)" >&2
    exit 0
fi

if grep -q "Served by slang over" "$dom"; then
    echo "ok    browser rendered the page over h2"
else
    echo "FAIL  page did not render"
    fails=$((fails + 1))
fi

# grep -o, not grep -c: --dump-dom emits the whole document on ONE
# line, so counting lines finds 1 no matter how many completed.
got=$(grep -o "done after 300ms" "$dom" | wc -l | tr -d " ")
if [ "$got" -eq 6 ]; then
    echo "ok    all six sub-resources completed"
else
    echo "FAIL  $got/6 sub-resources completed"
    fails=$((fails + 1))
fi

if grep -q "ALPN negotiated h2" "$work/log"; then
    echo "ok    server saw ALPN select h2"
else
    echo "FAIL  server never negotiated h2"
    fails=$((fails + 1))
fi

# Every /slow/N must land on the SAME connection -- that is what
# multiplexing means, and six connections would pass every check above.
conns=$(grep "GET /slow/" "$work/log" | sed 's/.*conn \([0-9]*\):.*/\1/' \
        | sort -u | wc -l | tr -d ' ')
if [ "$conns" -eq 1 ]; then
    echo "ok    six streams shared one connection"
else
    echo "FAIL  streams spread over $conns connections"
    fails=$((fails + 1))
fi

if grep -qE " (ERROR|WARN) |unexpected eof" "$work/log"; then
    echo "FAIL  browser disconnect logged an error:"
    grep -E " (ERROR|WARN) |unexpected eof" "$work/log" | head -3
    fails=$((fails + 1))
else
    echo "ok    browser disconnect read as a clean close"
fi

if [ "$fails" -ne 0 ]; then
    echo ""
    echo "$fails check(s) failed"
    exit 1
fi
echo ""
echo "all browser checks passed"
