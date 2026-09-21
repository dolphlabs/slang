#!/bin/sh
# slang test runner.
#
# Positive tests: tests/<name>/main.sl compiled with --run must exit 0
# and its stdout must match tests/<name>/expected.txt exactly.
#
# Negative tests: tests/fail_<name>/main.sl must fail (nonzero exit)
# at compile time or runtime. If tests/fail_<name>/expected_error.txt exists,
# its first line must also appear in the error output: a program that fails
# for some OTHER reason (a typo in the test, a regression elsewhere) would
# otherwise count as passing.
#
# stdin: a test that reads it (the io package) supplies tests/<name>/stdin.txt;
# every other test gets /dev/null. Inheriting the runner's stdin would make a
# test that reads it hang on a terminal, or read the CI job's own input.

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

    if [ -f "tests/$name/prepare.sh" ]; then
        # shellcheck disable=SC1090
        . "tests/$name/prepare.sh"
    fi

    stdin_file=/dev/null
    [ -f "tests/$name/stdin.txt" ] && stdin_file="tests/$name/stdin.txt"
    ./slangc "$t" --run >"$out" 2>"$err" <"$stdin_file"
    code=$?
    if [ "$code" -eq 0 ]; then
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
        if [ -f "tests/$name/expected.mir" ]; then
            if ./slangc "$t" --dump-mir >"/tmp/sl_${name}.mir" 2>"$err"; then
                if diff -u "tests/$name/expected.mir" "/tmp/sl_${name}.mir" >/tmp/sl_${name}.mir.diff; then
                    echo "PASS $name (mir)"
                else
                    echo "FAIL $name (mir dump mismatch)"
                    cat "/tmp/sl_${name}.mir.diff"
                    fail=1
                fi
            else
                echo "FAIL $name (--dump-mir error)"
                cat "$err"
                fail=1
            fi
        fi
    else
        # Exit code AND stdout, not just stderr: many tests report what went
        # wrong with println("FAIL ...") before exit(1), and 141 means a
        # signal (SIGPIPE) killed the process outright. Without both, an
        # intermittent CI failure showed only "compile or runtime error"
        # with nothing after it, and could not be diagnosed from the log.
        echo "FAIL $name (compile or runtime error, exit $code)"
        cat "$err"
        if [ -s "$out" ]; then
            echo "  --- stdout (last 10 lines) ---"
            tail -10 "$out" | sed 's/^/  /'
        fi
        fail=1
    fi
done

# negative tests: compilation or execution must fail
for t in tests/fail_*/main.sl; do
    dir=$(dirname "$t")
    name=$(basename "$dir")
    errout=$(./slangc "$t" --run 2>&1 >/dev/null </dev/null)
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "FAIL $name (expected failure, but it succeeded)"
        fail=1
    elif [ -f "$dir/expected_error.txt" ] &&
         ! printf '%s\n' "$errout" | grep -qF -- "$(head -1 "$dir/expected_error.txt")"; then
        echo "FAIL $name (failed, but not with the expected message)"
        echo "  wanted: $(head -1 "$dir/expected_error.txt")"
        printf '%s\n' "$errout" | head -3 | sed 's/^/  got:    /'
        fail=1
    else
        echo "PASS $name"
    fi
done

# ---- io: what a pipe cannot show ------------------------------------
# A prompt appearing before the person types, Ctrl-D / Ctrl-C on a terminal,
# and other tasks running while main waits for input all need a real tty.
echo "--- io (terminal and scheduling) ---"
if command -v python3 >/dev/null 2>&1; then
    python3 tests/io_tty/check.py ./slangc || fail=1
else
    echo "SKIP io terminal tests (python3 not found)"
fi

# flags.parse_or_exit's stdout, stderr and exit status are only visible
# from outside the process, so this builds a small program and runs it.
echo "--- flags (command line) ---"
if command -v python3 >/dev/null 2>&1; then
    python3 tests/flags_cli/check.py ./slangc || fail=1
else
    echo "SKIP flags command-line tests (python3 not found)"
fi

# ---- slangc new ------------------------------------------------------
# Scaffolding is part of the compiler, so it is part of the suite. The
# check is end-to-end on purpose: a project that is created but does not
# compile is worse than no scaffolding, because the first thing a new
# user does with it is run it.
echo "--- slangc new ---"
NEWDIR=$(mktemp -d)
if ./slangc new "$NEWDIR/scaffold" >/dev/null 2>&1 &&
   [ -f "$NEWDIR/scaffold/slang.project" ] &&
   [ -f "$NEWDIR/scaffold/main.sl" ] &&
   (cd "$NEWDIR/scaffold" && "$OLDPWD/slangc" main.sl --run 2>/dev/null |
        grep -q "hello from scaffold")
then
    # a second `new` over the same directory must refuse rather than clobber
    if ./slangc new "$NEWDIR/scaffold" >/dev/null 2>&1; then
        echo "FAIL slangc new (overwrote an existing slang.project)"
        fail=1
    else
        echo "PASS slangc new"
    fi
else
    echo "FAIL slangc new (scaffold did not build and run)"
    fail=1
fi
rm -rf "$NEWDIR"

# ---- slangc test ------------------------------------------------------
# End to end against fixture packages in tests/testcmd/ (they have no
# main.sl at the top level of tests/, so the loop above never runs them as
# ordinary tests).
echo "--- slangc test ---"
tc_bad=0
tc_fail() { echo "FAIL slangc test ($1)"; fail=1; tc_bad=1; }
tc_tmp_before=$(ls -d "${TMPDIR:-/tmp}"/slangtest_* 2>/dev/null | wc -l)

out=$(./slangc test tests/testcmd/lib 2>&1); code=$?
[ "$code" -eq 1 ] || tc_fail "a failing test must exit 1, got $code"
printf '%s\n' "$out" | grep -q '^ok   test_scaled ' || tc_fail "passing test not reported"
printf '%s\n' "$out" | grep -q '^ok   test_clamp_private ' || tc_fail "private function or global unreachable from a test"
printf '%s\n' "$out" | grep -q 'expected 99, got 20 at lib.test_fails_on_purpose:13' || tc_fail "failure message or location missing"
printf '%s\n' "$out" | grep -q '^ok   test_after_failure ' || tc_fail "run stopped at the first failure"
printf '%s\n' "$out" | grep -q 'helper_not_a_test must never run' && tc_fail "a non-test_ function was run"
printf '%s\n' "$out" | grep -q '^FAIL: 1 of 4 failed' || tc_fail "summary line wrong"

out=$(./slangc test tests/testcmd/lib --run clamp 2>&1); code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q '^ok: 1 passed' || tc_fail "--run filter"

# A PROGRAM under test: its top-level statements (which exit 7) must not run.
out=$(./slangc test tests/testcmd/prog 2>&1); code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q '^ok: 2 passed' || tc_fail "program package: tests did not run cleanly (exit $code)"

# ...and a normal build of that program must not contain test code.
rm -f main.gen.c
(cd tests/testcmd/prog && "$OLDPWD/slangc" main.sl --emit-c >/dev/null 2>&1)
if grep -q test_only_symbol_marker tests/testcmd/prog/main.gen.c 2>/dev/null; then
    tc_fail "a normal build compiled *_test.sl"
fi
rm -f tests/testcmd/prog/main.gen.c

./slangc test tests/testcmd/badsig >/dev/null 2>&1; code=$?
[ "$code" -eq 2 ] || tc_fail "a test with parameters must be rejected (exit 2), got $code"

out=$(./slangc test tests/testcmd/empty 2>&1); code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q 'no test files' || tc_fail "package without tests"

# Runners that compile are cleaned up. (One whose compile FAILS is kept on
# purpose for inspection, so compare against what was there before.)
tc_tmp_after=$(ls -d "${TMPDIR:-/tmp}"/slangtest_* 2>/dev/null | wc -l)
[ "$tc_tmp_after" -eq "$tc_tmp_before" ] || tc_fail "runner temp directories left behind"
[ "$tc_bad" -eq 0 ] && echo "PASS slangc test"

# Stdlib packages that carry their own unit tests.
for pkg in stdlib/pg; do
    if out=$(./slangc test "$pkg" 2>&1); then
        echo "PASS slangc test $pkg"
    else
        echo "FAIL slangc test $pkg"
        printf '%s\n' "$out" | grep -v '^ok ' | tail -20
        fail=1
    fi
done

# ---- GC at a tiny threshold ------------------------------------------
# A rooting bug -- a live object held only where no safepoint knows about
# it -- surfaces only when a collection lands at that exact safepoint. At
# the default threshold (8MB, growing to 256MB) collections are too rare
# to land there reliably, so these run again collecting every 16KB. Each
# of the first three was a real bug hidden for eleven days by the
# collector treating every task's recent allocations as roots.
echo "--- GC stress (SLANG_GC_THRESHOLD_KB=16) ---"
gc_bad=0
for name in gc_ctor_payload gc_map_put postgres http_client_pool http2_flood \
            spawn_isolation gc_stress maps json flags method_recv \
            method_recv_gc indirect_callee generics_structs generics_json generics_infer \
            generics_pkg gc_nested_literal; do
    out="/tmp/sl_gcstress_${name}.out"
    if ! SLANG_GC_THRESHOLD_KB=16 ./slangc "tests/$name/main.sl" --run \
            >"$out" 2>/dev/null; then
        echo "FAIL gc stress $name (exit $?)"
        tail -5 "$out" | sed 's/^/  /'
        gc_bad=1; fail=1
    elif ! diff -q "tests/$name/expected.txt" "$out" >/dev/null; then
        echo "FAIL gc stress $name (output mismatch)"
        gc_bad=1; fail=1
    fi
done
[ "$gc_bad" -eq 0 ] && echo "PASS gc stress"

# ---- frame guards --------------------------------------------------------
# A function whose C frame is large is compiled behind an entry guard that
# grows the stack first (see the frame loop in src/main.c). Real programs
# almost never need one, so the guard would go untested; a 64-byte limit puts
# one on nearly every function and on the main entry, on any compiler, and
# the output must not change. tests/big_frame is the one program that needs
# it for real: without the guard it dies with SIGBUS on clang.
echo "--- frame guards (SLANG_FRAME_LIMIT=64) ---"
fg_bad=0
for name in fn_values spawn_isolation gc_stress maps json flags method_recv \
            method_recv_own method_pub indirect_callee enum move own structs \
            mutex select big_frame generics_structs generics_pkg; do
    [ -f "tests/$name/main.sl" ] || continue
    out="/tmp/sl_fg_${name}.out"
    if ! SLANG_FRAME_LIMIT=64 ./slangc "tests/$name/main.sl" --run \
            >"$out" 2>/dev/null </dev/null; then
        echo "FAIL frame guards $name (exit $?)"
        fg_bad=1; fail=1
    elif ! diff -q "tests/$name/expected.txt" "$out" >/dev/null; then
        echo "FAIL frame guards $name (output mismatch)"
        fg_bad=1; fail=1
    fi
done
[ "$fg_bad" -eq 0 ] && echo "PASS frame guards"

# Generated C must compile clean under the warnings a C compiler turns
# on by ITSELF. slangc passes no -W flags, so anything default-on lands
# in the user's terminal on every single build -- 79 of them across this
# suite before the codegen was fixed to stop emitting `if ((a == b))`
# and bare statement-expressions. Sweeping every program keeps a new
# construct from quietly reintroducing the noise.
echo "--- generated C warning sweep ---"
warned=0
for t in tests/*/main.sl examples/*/main.sl; do
    name=$(basename "$(dirname "$t")")
    case "$name" in
        fail_*) continue ;;
    esac
    rm -f main.gen.c
    ./slangc "$t" --emit-c >/dev/null 2>&1 || continue
    [ -f main.gen.c ] || continue
    # -fsyntax-only, and cc run ONCE per program with its output kept:
    # this loop covers every test, so a second invocation just to
    # re-read the same diagnostics would double the suite's runtime for
    # nothing.
    diag=$(cc -fsyntax-only main.gen.c 2>&1 | grep 'warning:')
    if [ -n "$diag" ]; then
        w=$(printf '%s\n' "$diag" | wc -l | tr -d ' ')
        echo "FAIL $name ($w warning(s) in generated C)"
        printf '%s\n' "$diag" | head -3
        warned=$((warned + w))
        fail=1
    fi
done
rm -f main.gen.c
if [ "$warned" -eq 0 ]; then
    echo "PASS generated C is warning-free"
fi

if [ "$fail" -ne 0 ]; then
    echo "some tests failed"
    exit 1
fi
echo "all tests passed"