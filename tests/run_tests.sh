#!/bin/sh
# slang test runner.
#
# Positive tests: tests/<name>/main.sl compiled with --run must exit 0
# and its stdout must match tests/<name>/expected.txt exactly.
#
# Negative tests: tests/fail_<name>/main.sl must fail (nonzero exit)
# at compile time or runtime.

set -u
cd "$(dirname "$0")/.." || exit 1

fail=0

# tests/ffi links against a tiny hand-written C fixture library
# (tests/ffi/lib.c); build it once as a static archive and point
# LIBRARY_PATH at it so 'link "slffi";' resolves during the loop below.
ffi_build="/tmp/sl_ffi_build"
mkdir -p "$ffi_build"
if ! cc -std=c11 -O2 -Wall -Wextra -c tests/ffi/lib.c -o "$ffi_build/lib.o"; then
    echo "FAIL ffi (fixture library failed to build)"
    exit 1
fi
ar rcs "$ffi_build/libslffi.a" "$ffi_build/lib.o"
LIBRARY_PATH="$ffi_build${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LIBRARY_PATH

for t in tests/*/main.sl; do
    name=$(basename "$(dirname "$t")")
    case "$name" in
        fail_*) continue ;;
    esac

    out="/tmp/sl_${name}.out"
    err="/tmp/sl_${name}.err"

    if ./slangc "$t" --run >"$out" 2>"$err"; then
        if [ ! -f "tests/$name/expected.txt" ]; then
            echo "FAIL $name (missing tests/$name/expected.txt)"
            fail=1
        elif diff -u "tests/$name/expected.txt" "$out" >/tmp/sl_${name}.diff; then
            echo "PASS $name"
        else
            echo "FAIL $name (output mismatch)"
            cat "/tmp/sl_${name}.diff"
            fail=1
        fi
    else
        echo "FAIL $name (compile or runtime error)"
        cat "$err"
        fail=1
    fi
done

# negative tests: compilation or execution must fail
for t in tests/fail_*/main.sl; do
    name=$(basename "$(dirname "$t")")
    if ./slangc "$t" --run >/dev/null 2>&1; then
        echo "FAIL $name (expected failure, but it succeeded)"
        fail=1
    else
        echo "PASS $name"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "some tests failed"
    exit 1
fi
echo "all tests passed"