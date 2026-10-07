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
# A package README may show only the `pkg` line. The error for a project
# file without name/version must show the lines to add, not just refuse.
mkdir "$NEWDIR/pinonly"
echo 'pkg zokor git https://github.com/dolphlabs/zokor tag v0.1.0 dir src' \
    >"$NEWDIR/pinonly/slang.project"
if (cd "$NEWDIR/pinonly" && "$OLDPWD/slangc" get >out.txt 2>&1); then
    echo "FAIL slangc get (accepted a project file with no name/version)"
    fail=1
elif grep -q "missing the name and version lines" "$NEWDIR/pinonly/out.txt" &&
     grep -q "^  name app$" "$NEWDIR/pinonly/out.txt" &&
     grep -q "^  version 0.1.0$" "$NEWDIR/pinonly/out.txt"; then
    echo "PASS slangc get (missing name/version says the fix)"
else
    echo "FAIL slangc get (missing name/version error does not say the fix)"
    sed 's/^/  /' "$NEWDIR/pinonly/out.txt"
    fail=1
fi
# `slangc get` says where each package landed, under a path that can be
# typed: <cache>/pkg/<name>/<tag> links to the sha256:<64 hex> directory.
mkdir -p "$NEWDIR/getrepo/src" "$NEWDIR/getproj"
echo 'pub fn hi() -> str { return "hi"; }' >"$NEWDIR/getrepo/src/lib.sl"
(cd "$NEWDIR/getrepo" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m t &&
    git tag v1 && git branch rel/one)
printf 'name getproj\nversion 0.1.0\npkg demo git %s tag v1 dir src\npkg other git %s tag rel/one\n' \
    "$NEWDIR/getrepo" "$NEWDIR/getrepo" >"$NEWDIR/getproj/slang.project"
get_ok=1
for round in fetch cached; do
    out=$(cd "$NEWDIR/getproj" && SLANG_CACHE="$NEWDIR/cache" "$OLDPWD/slangc" get 2>&1) || get_ok=0
    printf '%s\n' "$out" | grep -qx "demo v1: $NEWDIR/cache/pkg/demo/v1/src" || get_ok=0
    printf '%s\n' "$out" | grep -qx "other rel/one: $NEWDIR/cache/pkg/other/rel_one" || get_ok=0
done
[ -f "$NEWDIR/cache/pkg/demo/v1/src/lib.sl" ] || get_ok=0
case "$(readlink "$NEWDIR/cache/pkg/demo/v1")" in sha256:*) ;; *) get_ok=0 ;; esac
if [ "$get_ok" -eq 1 ]; then
    echo "PASS slangc get (prints a typeable path per package)"
else
    echo "FAIL slangc get (typeable package path)"
    printf '%s\n' "$out" | sed 's/^/  /'
    fail=1
fi
rm -rf "$NEWDIR"

# ---- signals ------------------------------------------------------------
# SIGINT/SIGTERM are the program's to handle only if it asks
# proc.shutdown_requested(); otherwise they end it. And a second signal
# always ends it, so a drain that never finishes cannot make a server
# unkillable. Exit status 143 = killed by SIGTERM. Programs live in
# tests/signals/ (no main.sl at the top, so the loop above skips them).
# SIGINT is not driven here: a background job of a non-interactive shell
# starts with SIGINT ignored, and inheriting that is correct.
echo "--- signals ---"
sig_bad=0
sig_fail() { echo "FAIL signals ($1)"; fail=1; sig_bad=1; }
# Waits (up to 5s) for $2 to appear in file $1; 0 when it does.
sig_wait_line() {
    i=0
    while [ $i -lt 100 ]; do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
# Waits (up to 5s) for pid $1 to exit; 0 when it has.
sig_wait_exit() {
    i=0
    while [ $i -lt 100 ]; do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
for prog in no_poll second; do
    if ! ./slangc "tests/signals/$prog/main.sl" -o "/tmp/sl_sig_$prog" \
            >/dev/null 2>"/tmp/sl_sig_$prog.err"; then
        sig_fail "$prog: build"
        cat "/tmp/sl_sig_$prog.err"
    fi
done
if [ "$sig_bad" -eq 0 ]; then
    out=/tmp/sl_sig_no_poll.out
    /tmp/sl_sig_no_poll >"$out" 2>&1 &
    pid=$!
    if ! sig_wait_line "$out" "ready"; then
        sig_fail "no_poll: never ready"; kill -9 "$pid" 2>/dev/null
    else
        kill -TERM "$pid"
        if ! sig_wait_exit "$pid"; then
            sig_fail "no_poll: SIGTERM did not end a program that never polls"
            kill -9 "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null; code=$?
        [ "$code" -eq 143 ] || sig_fail "no_poll: exit $code, want 143"
    fi

    out=/tmp/sl_sig_second.out
    /tmp/sl_sig_second >"$out" 2>&1 &
    pid=$!
    if ! sig_wait_line "$out" "ready"; then
        sig_fail "second: never ready"; kill -9 "$pid" 2>/dev/null
    else
        kill -TERM "$pid"
        if ! sig_wait_line "$out" "shutdown requested"; then
            sig_fail "second: first SIGTERM was not a graceful request"
        fi
        kill -0 "$pid" 2>/dev/null || sig_fail "second: first SIGTERM ended it"
        kill -TERM "$pid"
        if ! sig_wait_exit "$pid"; then
            sig_fail "second: second SIGTERM did not end it"
            kill -9 "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null; code=$?
        [ "$code" -eq 143 ] || sig_fail "second: exit $code, want 143"
    fi
fi 2>/dev/null # the shell's own "Terminated" job notices; failures go to stdout
[ "$sig_bad" -eq 0 ] && echo "PASS signals"

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
# Quiet by default: only failures and the summary.
printf '%s\n' "$out" | grep -q '^ok   ' && tc_fail "a passing test printed a line without -v"
printf '%s\n' "$out" | grep -q '^FAIL test_fails_on_purpose ' || tc_fail "failure not reported without -v"
printf '%s\n' "$out" | grep -q '^FAIL: 1 of 4 failed' || tc_fail "summary line wrong without -v"
out=$(./slangc test tests/testcmd/lib -v 2>&1); code=$?
[ "$code" -eq 1 ] || tc_fail "-v: a failing test must exit 1, got $code"
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

# A test that waits for the tasks it spawned (proc.wait_idle) must
# finish: the runner's own task is not one of them. It used to hang, so
# it is run with a 60 s watchdog rather than trusted to return.
./slangc test tests/testcmd/idle >/tmp/sl_testcmd_idle.out 2>&1 &
idle_pid=$!
idle_i=0
while kill -0 "$idle_pid" 2>/dev/null && [ "$idle_i" -lt 120 ]; do
    sleep 0.5
    idle_i=$((idle_i + 1))
done
if kill -0 "$idle_pid" 2>/dev/null; then
    pkill -P "$idle_pid" 2>/dev/null
    kill "$idle_pid" 2>/dev/null
    wait "$idle_pid" 2>/dev/null
    tc_fail "proc.wait_idle() inside a test hung"
else
    wait "$idle_pid"; code=$?
    [ "$code" -eq 0 ] && grep -q '^ok: 2 passed' /tmp/sl_testcmd_idle.out ||
        tc_fail "wait_idle/active_tasks inside a test (exit $code)"
fi

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

# ---- slangc doc ---------------------------------------------------------
# An agent asks for the one API it needs. Packages resolve as `import` does
# from the current directory; source items come with the comment above them.
echo "--- slangc doc ---"
dc_bad=0
dc_fail() { echo "FAIL slangc doc ($1)"; fail=1; dc_bad=1; }
out=$(./slangc doc 2>&1) || dc_fail "listing exited nonzero"
printf '%s\n' "$out" | grep -q ' strings' || dc_fail "native packages not listed"
printf '%s\n' "$out" | grep -q ' http ' || dc_fail "standard library not listed"
out=$(./slangc doc builder 2>&1)
printf '%s\n' "$out" | grep -qx 'fn Str.write(self: Str, s: str) -> Str' || dc_fail "method line"
# A summary sits directly ABOVE its item, as in source; printed below,
# it read as the next item's comment.
printf '%s\n' "$out" | grep -B1 -x 'fn Str.write(self: Str, s: str) -> Str' |
    head -1 | grep -qx '// Appends, and returns the builder so writes chain.' || dc_fail "doc comment above its item"
out=$(cd tests/doccmd && "$OLDPWD/slangc" doc docpkg 2>&1)
printf '%s\n' "$out" | grep -B1 -x 'fn set_header(name: str, value: str) -> str' | head -1 |
    grep -qx '// Sets one header.' || dc_fail "listing: summary not above its own item"
printf '%s\n' "$out" | grep -B1 -x 'fn after_helper() -> int' | head -1 | grep -q '^//' &&
    dc_fail "listing: a private helper's comment reached the next item"
# Search: a name fragment, any case; then signatures and docs.
out=$(cd tests/doccmd && "$OLDPWD/slangc" doc docpkg HEADER 2>&1) || dc_fail "search by name exited nonzero"
printf '%s\n' "$out" | grep -qx 'fn set_header(name: str, value: str) -> str' || dc_fail "search: function by name"
printf '%s\n' "$out" | grep -qx 'fn Req.header(self: Req, name: str) -> str' || dc_fail "search: method by name"
printf '%s\n' "$out" | grep -q 'fn plain' && dc_fail "search: listed a non-match"
out=$(cd tests/doccmd && "$OLDPWD/slangc" doc docpkg.retry-after 2>&1) || dc_fail "search by doc exited nonzero"
printf '%s\n' "$out" | grep -qx 'fn set_header(name: str, value: str) -> str' || dc_fail "search: by doc text"
out=$(cd tests/doccmd && "$OLDPWD/slangc" doc docpkg.Req.header 2>&1)
[ "$out" = "$(printf '%s\n' '// The value of one request header.' 'fn header(self: Req, name: str) -> str')" ] ||
    dc_fail "exact item still shown in full: $out"
(cd tests/doccmd && "$OLDPWD/slangc" doc docpkg nothing_mentions_this >/dev/null 2>&1) &&
    dc_fail "search with no match must exit nonzero"
out=$(./slangc doc builder.Str 2>&1)
printf '%s\n' "$out" | grep -qx 'methods:' || dc_fail "struct shows its methods"
out=$(./slangc doc httpc.client_post 2>&1)
[ "$out" = "fn client_post(c: Client, url: str, content_type: str, body: bytes, deadline: until) -> result[Response, str]" ] \
    || dc_fail "multi-line signature joined: $out"
./slangc doc strings | grep -qx 'fn join(\[str\], str) -> str' || dc_fail "native list parameter"
(cd examples/pkgdemo && "$OLDPWD/slangc" doc geometry.area) | grep -qx 'fn area(w: float, h: float) -> float' \
    || dc_fail "local package"
./slangc doc json | grep -q '^fn decode(text: str) -> result\[T, str\]' || dc_fail "json note"
./slangc doc http no_such_item >/dev/null 2>&1 && dc_fail "missing item must exit nonzero"
./slangc doc no_such_pkg >/dev/null 2>&1 && dc_fail "missing package must exit nonzero"
[ "$dc_bad" -eq 0 ] && echo "PASS slangc doc"

# ---- deadlock guards -------------------------------------------------
# Programs that once deadlocked, under a 60 s watchdog each, since a hang
# in the main loop above would stall the whole suite. They live under
# tests/deadlock/ so that loop skips them. arena_churn: a task preempted
# inside an unbracketed free() held the allocator's large-block lock;
# run twice more with preemption forced to every millisecond (the old
# code hung in 6 of 10 forced runs).
echo "--- deadlock guards (60 s watchdog) ---"
dl_bad=0
for spec in "arena_churn" \
            "arena_churn:SLANG_PREEMPT_QUANTUM_MS=1 SLANG_PREEMPT_TICK_MS=1" \
            "arena_churn:SLANG_PREEMPT_QUANTUM_MS=1 SLANG_PREEMPT_TICK_MS=1"; do
    name=${spec%%:*}
    envs=""
    [ "$spec" != "$name" ] && envs=${spec#*:}
    out="/tmp/sl_deadlock_${name}.out"
    bin="/tmp/sl_deadlock_${name}.bin"
    if ! ./slangc "tests/deadlock/$name/main.sl" -o "$bin" >/dev/null 2>&1; then
        echo "FAIL deadlock guard $name (does not compile)"
        dl_bad=1; fail=1
        continue
    fi
    # shellcheck disable=SC2086
    env $envs "$bin" >"$out" 2>&1 &
    dl_pid=$!
    dl_i=0
    while kill -0 "$dl_pid" 2>/dev/null && [ "$dl_i" -lt 120 ]; do
        sleep 0.5
        dl_i=$((dl_i + 1))
    done
    if kill -0 "$dl_pid" 2>/dev/null; then
        kill -9 "$dl_pid" 2>/dev/null
        wait "$dl_pid" 2>/dev/null
        echo "FAIL deadlock guard $name ${envs:+($envs) }hung for 60 s"
        dl_bad=1; fail=1
    elif ! wait "$dl_pid" || ! diff -q "tests/deadlock/$name/expected.txt" "$out" >/dev/null; then
        echo "FAIL deadlock guard $name ${envs:+($envs) }(exit or output)"
        dl_bad=1; fail=1
    fi
    rm -f "$bin"
done
[ "$dl_bad" -eq 0 ] && echo "PASS deadlock guards"

# ---- preemption guards -----------------------------------------------
# Bugs that need an async preemption at one exact instruction, forced
# here to every millisecond on 4 workers with a 16KB nursery so a minor
# lands while the task is suspended. Three runs each. gc_preempt_derived:
# a new object held only by its header was invisible to the conservative
# scan (plain dev failed 9 of 10 runs). net_reactor_shards: waiters on
# every per-fd reactor list, woken by data and by deadlines, each once.
echo "--- preemption guards (forced 1 ms preemption, 16KB nursery) ---"
pg_bad=0
for name in gc_preempt_derived gc_preempt_derived gc_preempt_derived \
            net_reactor_shards net_reactor_shards net_reactor_shards; do
    out="/tmp/sl_preempt_${name}.out"
    if ! SLANG_WORKERS=4 SLANG_GC_NURSERY_KB=16 SLANG_PREEMPT_QUANTUM_MS=1 \
            SLANG_PREEMPT_TICK_MS=1 ./slangc "tests/$name/main.sl" --run \
            >"$out" 2>/dev/null; then
        echo "FAIL preemption guard $name (exit $?)"
        pg_bad=1; fail=1
    elif ! diff -q "tests/$name/expected.txt" "$out" >/dev/null; then
        echo "FAIL preemption guard $name: $(head -1 "$out")"
        pg_bad=1; fail=1
    fi
done
[ "$pg_bad" -eq 0 ] && echo "PASS preemption guards"

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
            spawn_isolation gc_stress maps json json_int_exact flags method_recv \
            method_recv_gc indirect_callee generics_structs generics_json generics_infer \
            generics_pkg gc_nested_literal generics_methods \
            generics_methods_pkg generics_methods_passes generics_late_instance generics_enum builder audit_roots loop_carry loop_leaf_poll own_roots switch escape_roots \
            http_read_wire bytes_empty_literal gc_minor_barriers map_delete if_let \
            literal_expect pending_sibling_type json_parity json_utf8 json_decode_budget \
            bytes json_deep_nesting gc_container_frontier gc_promotion_budget value_struct_containers json_value_structs gc_stw_sleep gc_preempt_derived; do
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

# ---- nursery stress (tiny young generation) ---------------------------
# Same discipline as the threshold loop above, applied to the nursery:
# a rooting or barrier bug in the generational collector -- a live young
# object the minor sweep frees, or an old->young edge the remembered set
# misses -- surfaces only when a minor collection lands at that exact
# safepoint. At the default nursery (512KB) minors are too rare to land
# there reliably, so the GC-bearing tests (plus the two nursery-specific
# ones) run again with a 16KB nursery, forcing a minor on nearly every
# allocation.
echo "--- nursery stress (SLANG_GC_NURSERY_KB=16) ---"
nur_bad=0
for name in gc_nursery_barrier gc_nursery_promotion gc_ctor_payload gc_map_put \
            gc_nested_literal gc_stress gc_stat spawn_isolation maps json \
            json_int_exact flags method_recv method_recv_gc indirect_callee \
            http_read_wire bytes_empty_literal gc_minor_barriers map_delete if_let \
            literal_expect pending_sibling_type json_parity json_utf8 json_decode_budget \
            bytes json_deep_nesting gc_container_frontier gc_promotion_budget value_struct_containers json_value_structs gc_stw_sleep; do
    out="/tmp/sl_nursery_${name}.out"
    if ! SLANG_GC_NURSERY_KB=16 ./slangc "tests/$name/main.sl" --run \
            >"$out" 2>/dev/null; then
        echo "FAIL nursery stress $name (exit $?)"
        tail -5 "$out" | sed 's/^/  /'
        nur_bad=1; fail=1
    elif ! diff -q "tests/$name/expected.txt" "$out" >/dev/null; then
        echo "FAIL nursery stress $name (output mismatch)"
        nur_bad=1; fail=1
    fi
done
[ "$nur_bad" -eq 0 ] && echo "PASS nursery stress"

# ---- minor collections checked against a full mark --------------------------
# A minor collection traces only young objects and the remembered set, so
# it is sound only if every store that leaves a young object held by an
# old one went through the write barrier. A missed barrier frees a live
# object, and nothing else in the suite would notice until it crashed.
# SLANG_GC_VERIFY_MINOR runs a full mark after every minor and counts the
# young objects the minor missed; with a 16KB nursery a minor lands on
# nearly every allocation. tests/gc_minor_barriers exercises each path
# that once had no barrier (see its header); the rest are the GC-heavy
# and task/channel/network tests. The count must be zero.
echo "--- minor collections verified (SLANG_GC_VERIFY_MINOR, 16KB nursery) ---"
vm_bad=0
for name in gc_minor_barriers gc_container_frontier gc_stress gc_ctor_payload gc_map_put if_let \
            literal_expect pending_sibling_type \
            gc_nested_literal gc_nursery_barrier gc_nursery_promotion \
            spawn_isolation select maps json json_parity json_utf8 json_decode_budget \
            bytes json_deep_nesting http_read_wire http_client_pool http2_flood \
            gc_promotion_budget \
            value_struct_containers json_value_structs gc_stw_sleep gc_preempt_derived; do
    [ -f "tests/$name/main.sl" ] || continue
    out="/tmp/sl_verify_minor_${name}.out"
    err="/tmp/sl_verify_minor_${name}.err"
    if ! SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16 \
            ./slangc "tests/$name/main.sl" --run >"$out" 2>"$err"; then
        echo "FAIL minor verify $name (exit $?)"
        tail -5 "$err" | sed 's/^/  /'
        vm_bad=1; fail=1
        continue
    fi
    missed=$(sed -n 's/^slang-gc-verify minors=[0-9]* missed=\([0-9]*\)$/\1/p' \
             "$err" | awk '{s += $1} END {print s + 0}')
    if [ "$missed" -ne 0 ]; then
        echo "FAIL minor verify $name: $missed live young object(s) missed"
        grep '^slang-gc-verify: ' "$err" | head -3 | sed 's/^/  /'
        vm_bad=1; fail=1
    elif ! diff -q "tests/$name/expected.txt" "$out" >/dev/null; then
        echo "FAIL minor verify $name (output mismatch)"
        vm_bad=1; fail=1
    fi
done
[ "$vm_bad" -eq 0 ] && echo "PASS minor collections verified"

# ---- allocation budgets ----------------------------------------------------
# GC allocations per operation, pinned for paths where the count is the
# point. Each program below has an ALLOC_BUDGET_N mode that repeats one
# operation N times and nothing else, so its SLANG_GC_STAT count at N minus
# its count at 0 is N operations' worth, which must not exceed N * per +
# slack. Going over is a regression to explain, not a number to re-pin;
# coming in under means the budget should come down with it.
#   http_read_wire       http.read + wants_close on a pipelined GET. Was
#                        20 (every ok()/err() and struct the parse threaded
#                        through, an opt per close check), then 7 with a
#                        bytes still two objects; 6 now: the WireHead, the
#                        path, the header block, and the Request, Incoming
#                        and result. The
#                        slack is for requests cut off at the end of the
#                        buffer: each such parse attempt makes a WireHead
#                        too (about 13 in 2000 here), and how often that
#                        happens depends on how the kernel splits the recvs.
#   bytes_empty_literal  b"" stored into a gc struct field. Was 2; a shared
#                        static now.
#   json_decode_budget   json.decode of a 20-item body into structs. Was 278
#                        (a parse-tree node per value, a copy of every
#                        number, a string per key); 47 now, the values the
#                        decode returns: 20 items and their skus, the Quote,
#                        its region, the list and its growth, and the result.
#   redis_read_budget    one redis PING round trip, client and in-process
#                        server together. Was 72, with the bytes copied per
#                        reply growing toward 1MB (the client appended every
#                        recv to its whole buffer); 70 now and flat. The
#                        slack covers a reply split across two recvs.
echo "--- allocation budgets (SLANG_GC_STAT) ---"
budget_bad=0
for spec in http_read_wire:2000:6:40 bytes_empty_literal:100000:0:0 \
            json_decode_budget:1000:47:0 redis_read_budget:1000:49:20; do
    IFS=: read -r name n per slack <<EOF_SPEC
$spec
EOF_SPEC
    bin="/tmp/sl_budget_${name}"
    if ! ./slangc "tests/$name/main.sl" -o "$bin" >/dev/null 2>&1; then
        echo "FAIL allocation budget $name (compile)"
        budget_bad=1; fail=1
        continue
    fi
    a0=$(SLANG_GC_STAT=1 ALLOC_BUDGET_N=0 "$bin" 2>&1 >/dev/null |
         sed -n 's/.* allocs=\([0-9]*\).*/\1/p' | head -1)
    an=$(SLANG_GC_STAT=1 ALLOC_BUDGET_N=$n "$bin" 2>&1 >/dev/null |
         sed -n 's/.* allocs=\([0-9]*\).*/\1/p' | head -1)
    rm -f "$bin"
    if [ -z "$a0" ] || [ -z "$an" ]; then
        echo "FAIL allocation budget $name (no slang-gc-stat line)"
        budget_bad=1; fail=1
    elif [ $((an - a0)) -gt $((n * per + slack)) ]; then
        echo "FAIL allocation budget $name: $((an - a0)) allocations for" \
             "$n operations, budget $per per operation + $slack"
        budget_bad=1; fail=1
    fi
done
[ "$budget_bad" -eq 0 ] && echo "PASS allocation budgets"

# ---- promotion budgets ------------------------------------------------------
# Objects promoted to the old generation, as a share of all allocations,
# for request-shaped workloads whose garbage must die young.
#   gc_promotion_budget  decode a 2,000-item body and walk it, 150 times.
#                        Was 30.7% promoted (one survival promoted, so a
#                        minor mid-walk promoted the whole tree); 0.28% with
#                        promotion after two survivals (fix-gc.md 1.2).
echo "--- promotion budgets (SLANG_GC_STAT) ---"
promo_bad=0
for spec in gc_promotion_budget:1; do
    name=${spec%%:*}
    pct=${spec#*:}
    stat=$(SLANG_GC_STAT=1 ./slangc "tests/$name/main.sl" --run 2>&1 >/dev/null |
           grep '^slang-gc-stat collects=')
    allocs=$(echo "$stat" | sed -n 's/.* allocs=\([0-9]*\).*/\1/p')
    promoted=$(echo "$stat" | sed -n 's/.* promoted=\([0-9]*\).*/\1/p')
    if [ -z "$allocs" ] || [ -z "$promoted" ]; then
        echo "FAIL promotion budget $name (no slang-gc-stat line)"
        promo_bad=1; fail=1
    elif [ $((promoted * 100)) -gt $((allocs * pct)) ]; then
        echo "FAIL promotion budget $name: $promoted of $allocs allocations" \
             "promoted, budget $pct%"
        promo_bad=1; fail=1
    fi
done
[ "$promo_bad" -eq 0 ] && echo "PASS promotion budgets"

# ---- nursery adaptation ------------------------------------------------------
# The nursery grows while minors cost more than an eighth of the time
# between them and stays at its 512 KB base while they are cheap
# (fix-gc.md 1.2a). nursery_threshold= is its size at exit.
#   gc_promotion_budget  decode-heavy: must have grown past the base (was
#                        fixed at 512 KB; minors 49 -> 5 here).
#   gc_nursery_small     short strings, nothing live: must stay at most
#                        1 MB.
echo "--- nursery adaptation (SLANG_GC_STAT) ---"
nur_ad_bad=0
for spec in gc_promotion_budget:grow gc_nursery_small:small; do
    name=${spec%%:*}
    want=${spec#*:}
    size=$(SLANG_GC_STAT=1 ./slangc "tests/$name/main.sl" --run 2>&1 >/dev/null |
           sed -n 's/^slang-gc-stat collects=.* nursery_threshold=\([0-9]*\).*/\1/p')
    if [ -z "$size" ]; then
        echo "FAIL nursery adaptation $name (no slang-gc-stat line)"
        nur_ad_bad=1; fail=1
    elif [ "$want" = grow ] && [ "$size" -le 524288 ]; then
        echo "FAIL nursery adaptation $name: still $size bytes, expected growth"
        nur_ad_bad=1; fail=1
    elif [ "$want" = small ] && [ "$size" -gt 1048576 ]; then
        echo "FAIL nursery adaptation $name: grew to $size bytes for cheap minors"
        nur_ad_bad=1; fail=1
    fi
done
[ "$nur_ad_bad" -eq 0 ] && echo "PASS nursery adaptation"

# ---- majors paced by promotion -----------------------------------------------
# A major comes after the live-paced threshold of PROMOTED bytes, or every
# 16 minors (sl_gc.c, SL_GC_MAJOR_EVERY). It used to come after 8 MB of
# any allocation: gc_promotion_budget decodes and drops large bodies,
# promotes almost nothing, and still ran 4 majors in 8 minors. Majors
# must stay at most minors/16 + 1.
echo "--- major pacing (SLANG_GC_STAT) ---"
mp=$(SLANG_GC_STAT=1 ./slangc tests/gc_promotion_budget/main.sl --run 2>&1 >/dev/null |
     sed -n 's/^slang-gc-stat collects=\([0-9]*\) minor_collects=\([0-9]*\) .*/\1 \2/p')
if [ -z "$mp" ]; then
    echo "FAIL major pacing (no slang-gc-stat line)"
    fail=1
elif [ "${mp% *}" -gt $(( ${mp#* } / 16 + 1 )) ]; then
    echo "FAIL major pacing: $mp (majors minors)"
    fail=1
else
    echo "PASS major pacing ($mp majors minors)"
fi

# ---- stopped threads sleep through a pause ------------------------------------
# A thread stopped for a collection spins a few microseconds, then sleeps
# until the pause ends (sl_gc_ack_and_wait). It used to call sched_yield
# in a loop for the whole pause: on Linux a syscall per turn that returned
# at once, 60% of the quote server's CPU in a Linux container. Four
# allocating tasks on four workers stop each other at every minor;
# SLANG_GC_STAT's stw line must show waits, and sleeps among them.
echo "--- stopped threads sleep (SLANG_GC_STAT) ---"
stw=$(SLANG_WORKERS=4 SLANG_GC_STAT=1 ./slangc tests/gc_stw_sleep/main.sl --run 2>&1 >/dev/null |
      sed -n 's/^slang-gc-stat stw_waits=\([0-9]*\) stw_sleeps=\([0-9]*\)$/\1 \2/p')
if [ -z "$stw" ]; then
    echo "FAIL stopped threads sleep (no slang-gc-stat stw line)"
    fail=1
elif [ "${stw#* }" -eq 0 ]; then
    echo "FAIL stopped threads sleep: waits/sleeps $stw"
    fail=1
else
    echo "PASS stopped threads sleep (waits/sleeps $stw)"
fi

# ---- young pages hold a whole cycle -----------------------------------------
# A small object that finds no room on its worker's pages falls back to
# a libc malloc, freed one by one at the sweep. The page cap was sized
# for the fixed 512 KB nursery; once the nursery grew (above), a
# decode-heavy cycle overflowed it and gc_promotion_budget took 465,912
# fallbacks, a third of the decode probe's allocations. The cap now
# covers the largest nursery (sl_gc.c, SL_GC_PAGE_MAX_PAGES), and the
# count must be zero. SLANG_GC_CLASS_STAT prints it at exit.
echo "--- young page fallback (SLANG_GC_CLASS_STAT) ---"
fb=$(SLANG_GC_CLASS_STAT=1 ./slangc tests/gc_promotion_budget/main.sl --run 2>&1 >/dev/null |
     sed -n 's/^slang-gc-page-stat .* fallback=\([0-9]*\).*/\1/p')
if [ -z "$fb" ]; then
    echo "FAIL young page fallback (no slang-gc-page-stat line)"
    fail=1
elif [ "$fb" -ne 0 ]; then
    echo "FAIL young page fallback: $fb small objects fell back to malloc"
    fail=1
else
    echo "PASS young page fallback"
fi

# ---- async preemption: C called on an aligned stack ------------------------
# The async-preemption trampoline calls into C (sl_preempt_yield and two
# helpers), and System V requires %rsp 16-byte aligned at every call. An
# interrupt can land with %rsp 8 off, and the trampoline once passed that
# straight through: 17-21% of these preemptions called C misaligned. No
# callee happened to use an aligned SSE spill, so nothing crashed, but any
# compiler is entitled to emit one there. SLANG_SCHED_STAT counts calls
# that arrive misaligned (a probe inside sl_preempt_yield); CPU-bound
# tasks under a 1ms tick and quantum get hundreds of async preemptions,
# and the count must be zero. arm64 keeps sp aligned in hardware, so
# there it checks only that the preemptions happen.
echo "--- async preemption alignment (SLANG_SCHED_STAT) ---"
pa_bin=/tmp/sl_preempt_align
if ! ./slangc tests/sched_fairness/main.sl -o "$pa_bin" >/dev/null 2>&1; then
    echo "FAIL async preemption alignment (compile)"
    fail=1
else
    pa_stat=$(SLANG_SCHED_STAT=1 SLANG_PREEMPT_TICK_MS=1 \
              SLANG_PREEMPT_QUANTUM_MS=1 "$pa_bin" 2>&1 >/dev/null |
              grep '^slang-sched-stat')
    pa_async=$(printf '%s\n' "$pa_stat" |
               sed -n 's/.* async_preempts=\([0-9]*\).*/\1/p')
    pa_mis=$(printf '%s\n' "$pa_stat" |
             sed -n 's/.* misaligned_preempts=\([0-9]*\).*/\1/p')
    if [ -z "$pa_async" ] || [ -z "$pa_mis" ]; then
        echo "FAIL async preemption alignment (no slang-sched-stat line)"
        fail=1
    elif [ "$pa_async" -lt 20 ]; then
        echo "FAIL async preemption alignment: only $pa_async async" \
             "preemptions, too few to test"
        fail=1
    elif [ "$pa_mis" -ne 0 ]; then
        echo "FAIL async preemption alignment: $pa_mis of $pa_async" \
             "called C with a misaligned stack"
        fail=1
    else
        echo "PASS async preemption alignment ($pa_async async preemptions)"
    fi
fi
rm -f "$pa_bin"

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
            mutex select big_frame generics_structs generics_pkg \
            generics_methods; do
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

# ---- llms-small.txt ------------------------------------------------------
# www/llms-small.md is the one hand-written digest on the docs site: the
# language on one page for a model's context window (www/build.py says why
# it is the exception). A model copies its examples as written, so a block
# that no longer compiles teaches every agent that reads it the wrong thing.
# Each ```slang block is a whole program and must compile and exit 0.
echo "--- llms-small.txt examples ---"
ls_dir=$(mktemp -d /tmp/sl_llms.XXXXXX)
awk -v dir="$ls_dir" '
    /^```slang$/ { n++; f = sprintf("%s/b%02d", dir, n);
                   system("mkdir -p " f); out = f "/main.sl"; inb = 1; next }
    /^```$/      { if (inb) { close(out); inb = 0 } next }
    inb          { print > out }
' www/llms-small.md
ls_bad=0
ls_n=0
for b in "$ls_dir"/b*; do
    [ -f "$b/main.sl" ] || continue
    ls_n=$((ls_n + 1))
    if ! ./slangc "$b/main.sl" --run >"$b/out" 2>&1 </dev/null; then
        echo "FAIL llms-small.txt example $(basename "$b")"
        tail -3 "$b/out"
        ls_bad=1; fail=1
    fi
done
if [ "$ls_n" -eq 0 ]; then
    echo "FAIL llms-small.txt: no \`\`\`slang examples found"
    ls_bad=1; fail=1
fi
rm -rf "$ls_dir"
[ "$ls_bad" -eq 0 ] && echo "PASS llms-small.txt examples ($ls_n)"

# ---- compiler diagnostics --------------------------------------------------
# An agent or editor acts on the compiler's errors, so their shape is an
# interface: file:line: error: message, the first error of EVERY function in
# one compile (not only the program's first), a "did you mean" where one is
# likely, and with --json one object per error that carries the same facts.
# tests/fail_diagnostics has errors in two files; its whole stderr is pinned.
echo "--- compiler diagnostics ---"
dg_bad=0
dg=tests/fail_diagnostics
if ./slangc "$dg/main.sl" >/dev/null 2>/tmp/sl_diag.err </dev/null; then
    echo "FAIL diagnostics: the fixture compiled"
    dg_bad=1; fail=1
elif ! diff -u "$dg/expected_stderr.txt" /tmp/sl_diag.err >/tmp/sl_diag.diff; then
    echo "FAIL diagnostics: stderr differs"
    cat /tmp/sl_diag.diff
    dg_bad=1; fail=1
fi
./slangc "$dg/main.sl" --json >/dev/null 2>/tmp/sl_diag.json </dev/null
if ! python3 - /tmp/sl_diag.json "$dg/expected_stderr.txt" <<'PY'
import json, sys
got = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
want = [l.rstrip("\n") for l in open(sys.argv[2]) if l.strip()]
assert len(got) == len(want), "%d JSON errors, %d text ones" % (len(got), len(want))
for g, w in zip(got, want):
    assert set(g) == {"file", "line", "severity", "message"}, g
    assert g["severity"] == "error", g
    text = "%s:%d: error: %s" % (g["file"], g["line"], g["message"])
    assert text == w, (text, w)
PY
then
    echo "FAIL diagnostics: --json output"
    dg_bad=1; fail=1
fi
[ "$dg_bad" -eq 0 ] && echo "PASS compiler diagnostics"

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