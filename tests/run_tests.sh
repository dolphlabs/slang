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