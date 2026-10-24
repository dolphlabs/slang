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

# `slangc test` on a package that imports a pinned dependency. The runner
# it generates lives in a temporary directory, outside the project, so the
# pins have to come from the package under test's project.
mkdir -p "$NEWDIR/getproj/lib"
printf 'import "demo";\n\npub fn greet() -> str {\n    return demo.hi();\n}\n' \
    >"$NEWDIR/getproj/lib/lib.sl"
printf 'fn test_greet_uses_the_pinned_package() {\n    assert(greet() == "hi");\n}\n' \
    >"$NEWDIR/getproj/lib/lib_test.sl"
out=$(cd "$NEWDIR/getproj" && SLANG_CACHE="$NEWDIR/cache" "$OLDPWD/slangc" test lib 2>&1)
if printf '%s\n' "$out" | grep -q '^ok: 1 passed'; then
    echo "PASS slangc test (a package importing a pinned dependency)"
else
    echo "FAIL slangc test (a package importing a pinned dependency)"
    printf '%s\n' "$out" | sed 's/^/  /'
    fail=1
fi

# A package may omit non-runtime directories from its distributable checkout.
# The root manifest remains available for transitive dependency resolution,
# included source still compiles, and included source remains hash-verified.
echo "--- package exclusions ---"
mkdir -p "$NEWDIR/exclude_demo/src" "$NEWDIR/exclude_demo/bench" \
    "$NEWDIR/exclude_demo/examples" "$NEWDIR/exclude_helper/src" \
    "$NEWDIR/exclude_helper/bench" "$NEWDIR/exclude_app"
printf 'name demo\nversion 0.1.0\nexclude bench\nexclude examples\npkg helper git file://%s/exclude_helper tag v1\n' \
    "$NEWDIR" >"$NEWDIR/exclude_demo/slang.project"
printf 'import "helper";\npub fn hi() -> str { return helper.value(); }\n' \
    >"$NEWDIR/exclude_demo/src/lib.sl"
printf 'benchmark fixture\n' >"$NEWDIR/exclude_demo/bench/data.txt"
printf 'example fixture\n' >"$NEWDIR/exclude_demo/examples/main.sl"
printf 'name helper\nversion 0.1.0\nexclude bench\n' \
    >"$NEWDIR/exclude_helper/slang.project"
printf 'pub fn value() -> str { return "kept"; }\n' \
    >"$NEWDIR/exclude_helper/src/lib.sl"
printf 'helper benchmark fixture\n' \
    >"$NEWDIR/exclude_helper/bench/data.txt"
for repo in "$NEWDIR/exclude_demo" "$NEWDIR/exclude_helper"; do
    (cd "$repo" && git init -q && git add . &&
        git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
            commit -q -m t && git tag v1 &&
        git config uploadpack.allowFilter true)
done
cat >"$NEWDIR/exclude_app/slang.project" <<EOF
name excludeapp
version 0.1.0
pkg demo git file://$NEWDIR/exclude_demo tag v1 dir src
EOF
cat >"$NEWDIR/exclude_app/main.sl" <<'EOF'
import "demo";
println(demo.hi());
EOF
exclude_ok=1
if ! (cd "$NEWDIR/exclude_app" && SLANG_CACHE="$NEWDIR/cache" \
        "$OLDPWD/slangc" get >get.txt 2>&1); then
    exclude_ok=0
fi
demo_hash=$(readlink "$NEWDIR/cache/pkg/demo/v1" 2>/dev/null || true)
helper_hash=$(readlink "$NEWDIR/cache/pkg/helper/v1" 2>/dev/null || true)
demo_cache="$NEWDIR/cache/pkg/demo/$demo_hash"
helper_cache="$NEWDIR/cache/pkg/helper/$helper_hash"
[ -f "$demo_cache/src/lib.sl" ] || exclude_ok=0
[ -f "$helper_cache/src/lib.sl" ] || exclude_ok=0
[ ! -e "$demo_cache/bench" ] || exclude_ok=0
[ ! -e "$demo_cache/examples" ] || exclude_ok=0
[ ! -e "$helper_cache/bench" ] || exclude_ok=0
[ ! -e "$demo_cache/.git" ] || exclude_ok=0
[ ! -e "$helper_cache/.git" ] || exclude_ok=0
if [ "$exclude_ok" -eq 1 ] &&
   (cd "$NEWDIR/exclude_app" && SLANG_CACHE="$NEWDIR/cache" \
       "$OLDPWD/slangc" main.sl --run >run.txt 2>run.err) &&
   grep -qx kept "$NEWDIR/exclude_app/run.txt"; then
    printf 'changed included source\n' >"$demo_cache/src/lib.sl"
    if (cd "$NEWDIR/exclude_app" && SLANG_CACHE="$NEWDIR/cache" \
            "$OLDPWD/slangc" main.sl --run >bad.txt 2>&1) ||
       ! grep -q "package 'demo' hash mismatch" "$NEWDIR/exclude_app/bad.txt"; then
        exclude_ok=0
    fi
fi
if [ "$exclude_ok" -eq 1 ]; then
    echo "PASS package exclusions (transitive fetch, source, and lock hash)"
else
    echo "FAIL package exclusions"
    [ ! -f "$NEWDIR/exclude_app/get.txt" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_app/get.txt"
    [ ! -f "$NEWDIR/exclude_app/run.err" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_app/run.err"
    [ ! -f "$NEWDIR/exclude_app/bad.txt" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_app/bad.txt"
    fail=1
fi

# A remote may reject the partial-clone filter rather than ignore it. Ensure
# `slangc get` retries as a shallow clone and still prunes excluded paths.
mkdir -p "$NEWDIR/reject-filter-bin"
REAL_GIT=$(command -v git)
cat >"$NEWDIR/reject-filter-bin/git" <<EOF
#!/bin/sh
for arg do
    [ "\$arg" = "--filter=blob:none" ] && exit 1
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$NEWDIR/reject-filter-bin/git"
fallback_ok=1
if ! (cd "$NEWDIR/exclude_app" && \
      PATH="$NEWDIR/reject-filter-bin:$PATH" \
      SLANG_CACHE="$NEWDIR/fallback_cache" \
      "$OLDPWD/slangc" get >fallback.txt 2>&1); then
    fallback_ok=0
fi
fallback_hash=$(readlink "$NEWDIR/fallback_cache/pkg/demo/v1" 2>/dev/null || true)
fallback_cache="$NEWDIR/fallback_cache/pkg/demo/$fallback_hash"
[ -f "$fallback_cache/src/lib.sl" ] || fallback_ok=0
[ ! -e "$fallback_cache/bench" ] || fallback_ok=0
[ ! -e "$fallback_cache/examples" ] || fallback_ok=0
[ ! -e "$fallback_cache/.git" ] || fallback_ok=0
if [ "$fallback_ok" -eq 1 ]; then
    echo "PASS package exclusions (retries when partial clone is rejected)"
else
    echo "FAIL package exclusions (partial-clone fallback)"
    [ ! -f "$NEWDIR/exclude_app/fallback.txt" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_app/fallback.txt"
    fail=1
fi

# Exclusion paths are literal relative directories. Reject traversal before
# using any manifest value to shape a Git sparse-checkout pattern.
mkdir -p "$NEWDIR/exclude_bad/src" "$NEWDIR/exclude_bad_app"
printf 'name bad\nversion 0.1.0\nexclude ../outside\n' \
    >"$NEWDIR/exclude_bad/slang.project"
printf 'pub fn hi() -> str { return "bad"; }\n' \
    >"$NEWDIR/exclude_bad/src/lib.sl"
(cd "$NEWDIR/exclude_bad" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m t && git tag v1)
cat >"$NEWDIR/exclude_bad_app/slang.project" <<EOF
name excludebad
version 0.1.0
pkg bad git $NEWDIR/exclude_bad tag v1 dir src
EOF
if (cd "$NEWDIR/exclude_bad_app" && SLANG_CACHE="$NEWDIR/cache" \
        "$OLDPWD/slangc" get >out.txt 2>&1) ||
   ! grep -q "expected 'exclude <subdir>'" "$NEWDIR/exclude_bad_app/out.txt"; then
    echo "FAIL package exclusions (rejects traversal path)"
    [ ! -f "$NEWDIR/exclude_bad_app/out.txt" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_bad_app/out.txt"
    fail=1
else
    echo "PASS package exclusions (rejects traversal path)"
fi
printf 'name bad\nversion 0.1.0\nexclude src\n' \
    >"$NEWDIR/exclude_bad/slang.project"
(cd "$NEWDIR/exclude_bad" && git add slang.project &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m conflict && git tag v2)
cat >"$NEWDIR/exclude_bad_app/slang.project" <<EOF
name excludebad
version 0.1.0
pkg bad git $NEWDIR/exclude_bad tag v2 dir src
EOF
if (cd "$NEWDIR/exclude_bad_app" && SLANG_CACHE="$NEWDIR/cache" \
        "$OLDPWD/slangc" get >out.txt 2>&1) ||
   ! grep -q "package 'bad' selects dir 'src', but its manifest excludes" \
       "$NEWDIR/exclude_bad_app/out.txt"; then
    echo "FAIL package exclusions (rejects excluded package dir)"
    [ ! -f "$NEWDIR/exclude_bad_app/out.txt" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_bad_app/out.txt"
    fail=1
else
    echo "PASS package exclusions (rejects excluded package dir)"
fi
rm "$NEWDIR/exclude_bad/slang.project"
printf 'name bad\nversion 0.1.0\nexclude ../outside\n' \
    >"$NEWDIR/exclude_bad/metadata.txt"
ln -s metadata.txt "$NEWDIR/exclude_bad/slang.project"
(cd "$NEWDIR/exclude_bad" && git add slang.project metadata.txt &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m symlink && git tag v3)
cat >"$NEWDIR/exclude_bad_app/slang.project" <<EOF
name excludebad
version 0.1.0
pkg bad git $NEWDIR/exclude_bad tag v3 dir src
EOF
if (cd "$NEWDIR/exclude_bad_app" && SLANG_CACHE="$NEWDIR/cache" \
        "$OLDPWD/slangc" get >out.txt 2>&1) ||
   ! grep -q "package manifest .* must be a regular file" \
       "$NEWDIR/exclude_bad_app/out.txt"; then
    echo "FAIL package exclusions (rejects symlink manifest)"
    [ ! -f "$NEWDIR/exclude_bad_app/out.txt" ] ||
        sed 's/^/  /' "$NEWDIR/exclude_bad_app/out.txt"
    fail=1
else
    echo "PASS package exclusions (rejects symlink manifest)"
fi

# Git treats a path as local unless it has a scheme or a colon before its
# first slash. A local path containing ':' must not get --depth/--filter,
# which Git ignores for local clones with a warning on every fetch.
mkdir -p "$NEWDIR/colon:repo/src" "$NEWDIR/colon_app"
printf 'pub fn hi() -> str { return "colon"; }\n' \
    >"$NEWDIR/colon:repo/src/lib.sl"
(cd "$NEWDIR/colon:repo" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m t && git tag v1)
cat >"$NEWDIR/colon_app/slang.project" <<EOF
name colonapp
version 0.1.0
pkg colon git $NEWDIR/colon:repo tag v1 dir src
EOF
if ! (cd "$NEWDIR/colon_app" && SLANG_CACHE="$NEWDIR/cache" \
        "$OLDPWD/slangc" get >out.txt 2>&1) ||
   grep -q "ignored in local clones" "$NEWDIR/colon_app/out.txt"; then
    echo "FAIL package exclusions (local path with ':' cloned as remote)"
    sed 's/^/  /' "$NEWDIR/colon_app/out.txt"
    fail=1
else
    echo "PASS package exclusions (local path with ':' cloned as local)"
fi

# An exclude inside the package's own directory is allowed while nothing
# imports it. Once the package imports it, the import must be refused:
# the directory was never fetched, and `import "json"` would otherwise
# fall through to the native json package and run code nobody wrote.
mkdir -p "$NEWDIR/exclude_nested/src/json" \
    "$NEWDIR/exclude_nested/src/testdata" "$NEWDIR/exclude_nested_app"
printf 'name nested\nversion 0.1.0\nexclude src/testdata\nexclude src/json\n' \
    >"$NEWDIR/exclude_nested/slang.project"
printf 'pub fn hi() -> str { return "own"; }\n' \
    >"$NEWDIR/exclude_nested/src/lib.sl"
printf 'pub fn encode(x: int) -> str { return "own-json"; }\n' \
    >"$NEWDIR/exclude_nested/src/json/json.sl"
printf 'fixture\n' >"$NEWDIR/exclude_nested/src/testdata/data.txt"
(cd "$NEWDIR/exclude_nested" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m t && git tag v1)
printf 'import "json";\npub fn hi() -> str { return json.encode(1); }\n' \
    >"$NEWDIR/exclude_nested/src/lib.sl"
(cd "$NEWDIR/exclude_nested" && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m imports && git tag v2)
printf 'import "nested";\nprintln(nested.hi());\n' \
    >"$NEWDIR/exclude_nested_app/main.sl"
nested_run() { # tag -> run.txt
    printf 'name nestedapp\nversion 0.1.0\npkg nested git %s/exclude_nested tag %s dir src\n' \
        "$NEWDIR" "$1" >"$NEWDIR/exclude_nested_app/slang.project"
    rm -f "$NEWDIR/exclude_nested_app/slang.lock"
    (cd "$NEWDIR/exclude_nested_app" && SLANG_CACHE="$NEWDIR/cache" \
        "$OLDPWD/slangc" get >run.txt 2>&1 &&
        SLANG_CACHE="$NEWDIR/cache" "$OLDPWD/slangc" main.sl --run \
            >run.txt 2>&1)
}
nested_hash=
if nested_run v1 && grep -qx own "$NEWDIR/exclude_nested_app/run.txt"; then
    nested_hash=$(readlink "$NEWDIR/cache/pkg/nested/v1")
fi
if [ -z "$nested_hash" ] ||
   [ -e "$NEWDIR/cache/pkg/nested/$nested_hash/src/testdata" ]; then
    echo "FAIL package exclusions (unimported exclude inside dir)"
    sed 's/^/  /' "$NEWDIR/exclude_nested_app/run.txt"
    fail=1
else
    echo "PASS package exclusions (unimported exclude inside dir)"
fi
if nested_run v2 ||
   ! grep -q "package 'nested' imports 'json', but its slang.project has 'exclude src/json'" \
       "$NEWDIR/exclude_nested_app/run.txt"; then
    echo "FAIL package exclusions (refuses import of excluded dir)"
    sed 's/^/  /' "$NEWDIR/exclude_nested_app/run.txt"
    fail=1
else
    echo "PASS package exclusions (refuses import of excluded dir)"
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
for pkg in stdlib/pg stdlib/timez; do
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
# reactor_nudges: deadline waits racing the reactor's scans, which the
# registration count (sl_reactor_wake_at) must never let it sleep past.
# spawn_join_local: joined spawns that wake no worker, preempted between
# the spawn and the join, must still run (sl_task_submit_copy_joined).
echo "--- preemption guards (forced 1 ms preemption, 16KB nursery) ---"
pg_bad=0
for name in gc_preempt_derived gc_preempt_derived gc_preempt_derived \
            net_reactor_shards net_reactor_shards net_reactor_shards \
            reactor_nudges reactor_nudges spawn_join_local spawn_join_local \
            net_dns_records; do
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
for name in gc_ctor_payload gc_map_put pg_rows_as postgres http_client_pool http2_flood encoding_f64 crypto \
            spawn_isolation gc_stress maps json json_int_exact flags method_recv \
            method_recv_gc indirect_callee generics_structs generics_json generics_infer \
            generics_pkg gc_nested_literal generics_methods \
            generics_methods_pkg generics_methods_passes generics_late_instance generics_enum builder audit_roots loop_carry loop_leaf_poll loop_leaf_plus own_roots switch escape_roots \
            http_read_wire bytes_empty_literal gc_minor_barriers net_dns_records map_delete if_let \
            literal_expect pending_sibling_type big_list_literal leaf_native_calls method_receiver_root leaf_functions json_parity json_utf8 json_decode_budget \
            bytes json_deep_nesting gc_container_frontier gc_promotion_budget gc_chan_promotion_budget value_struct_containers json_value_structs gc_stw_sleep gc_preempt_derived gc_pointer_free gc_payload_trace gc_many_tasks gc_idle_tasks; do
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
for name in gc_nursery_barrier gc_nursery_promotion gc_ctor_payload gc_map_put encoding_f64 crypto \
            gc_nested_literal gc_stress gc_stat spawn_isolation maps pg_rows_as json \
            json_int_exact flags method_recv method_recv_gc indirect_callee \
            http_read_wire bytes_empty_literal gc_minor_barriers net_dns_records map_delete if_let \
            literal_expect pending_sibling_type big_list_literal leaf_native_calls method_receiver_root leaf_functions loop_leaf_plus json_parity json_utf8 json_decode_budget \
            bytes json_deep_nesting gc_container_frontier gc_promotion_budget gc_chan_promotion_budget value_struct_containers json_value_structs gc_stw_sleep gc_pointer_free gc_payload_trace gc_many_tasks gc_idle_tasks; do
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
for name in gc_minor_barriers gc_container_frontier gc_stress gc_ctor_payload gc_map_put encoding_f64 crypto if_let \
            literal_expect pending_sibling_type big_list_literal leaf_native_calls method_receiver_root leaf_functions loop_leaf_plus \
            gc_nested_literal gc_nursery_barrier gc_nursery_promotion net_dns_records \
            spawn_isolation select maps pg_rows_as json json_parity json_utf8 json_decode_budget \
            bytes json_deep_nesting redis http_read_wire http_client_pool http2_flood \
            gc_promotion_budget gc_chan_promotion_budget \
            value_struct_containers json_value_structs gc_stw_sleep gc_preempt_derived gc_pointer_free gc_payload_trace gc_many_tasks gc_idle_tasks gc_skip_queued \
            spawn_join_local spawn_call_args link_tls link_split fn_value_shadows_function select_send_escapes; do
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
#   http_write_extra_budget  http.write of a JSON response with a request
#                        id and three security headers. With the id alone
#                        it was 52: the general emit rebuilt and lowercased
#                        every header name per line in each of its two
#                        passes; then 2: the line's bytes, once per pass.
#                        A line that cannot be content-length, connection,
#                        content-type or location is written uncopied:
#                        first by its first letter (0 for the id), now
#                        also by where its colon is (0, not 4, with
#                        content-security-policy and cache-control).
#   builder_bytes_lazy   builder.new_bytes, one long write, take. Was 8 (a
#                        512-byte chunk built as a str then copied to
#                        bytes before any write, and take always joining);
#                        5 now: the builder, its piece list, the piece,
#                        the reset's new list and its growth.
#   redis_read_budget    one redis PING round trip, client and in-process
#                        server together. Was 72, with the bytes copied per
#                        reply growing toward 1MB (the client appended every
#                        recv to its whole buffer); 70 now and flat. The
#                        slack covers a reply split across two recvs.
echo "--- allocation budgets (SLANG_GC_STAT) ---"
budget_bad=0
for spec in http_read_wire:2000:6:40 bytes_empty_literal:100000:0:0 \
            json_decode_budget:1000:47:0 redis_read_budget:1000:49:20 \
            http_write_extra_budget:10000:0:0 \
            builder_bytes_lazy:10000:5:0; do
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

# ---- reactor nudge budget ---------------------------------------------------
# reactor_nudges: keep-alive round trips where every recv carries a
# deadline. A deadline wait nudges the reactor (a write(2) and an extra
# reactor wakeup) only when the reactor would otherwise sleep past it.
# Before the registration-count protocol and the 1 s sleep cap
# (runtime/sl_net.c, sl_reactor_wake_at) 41-56% of these waits nudged,
# because a reactor mid-scan read as "nudge me"; none do now. Budget: 1%.
echo "--- reactor nudge budget (SLANG_SCHED_STAT) ---"
nudge_line=$(SLANG_SCHED_STAT=1 ./slangc tests/reactor_nudges/main.sl --run \
             2>&1 >/dev/null | grep -o 'deadline_waits=[0-9]* reactor_nudges=[0-9]*')
nudge_waits=$(echo "$nudge_line" | sed -n 's/deadline_waits=\([0-9]*\).*/\1/p')
nudge_n=$(echo "$nudge_line" | sed -n 's/.*reactor_nudges=\([0-9]*\)/\1/p')
if [ -z "$nudge_waits" ] || [ -z "$nudge_n" ] || [ "$nudge_waits" -lt 1000 ]; then
    echo "FAIL reactor nudge budget (no slang-sched-stat line: $nudge_line)"
    fail=1
elif [ $((nudge_n * 100)) -gt "$nudge_waits" ]; then
    echo "FAIL reactor nudge budget: $nudge_n nudges for $nudge_waits" \
         "deadline waits, budget 1%"
    fail=1
else
    echo "PASS reactor nudge budget ($nudge_n nudges, $nudge_waits deadline waits)"
fi

# ---- idle queued tasks skipped by minors ------------------------------------
# gc_skip_queued: 2000 tasks woken at once wait in the run queue on one
# worker while main allocates through hundreds of minors. Each minor may
# leave out a queued task that has not run since two minors ago, as it
# does a parked one. Only parked ones used to be: 7639 of 160789 task
# visits skipped (5%); 96% now. Budget: at least half.
echo "--- idle queued tasks skipped (SLANG_GC_STAT) ---"
sq_err=$(SLANG_WORKERS=1 SLANG_PREEMPT_QUANTUM_MS=10000 SLANG_GC_NURSERY_KB=64 SLANG_GC_STAT=1 \
         ./slangc tests/gc_skip_queued/main.sl --run 2>&1 >/dev/null)
sq_walked=$(echo "$sq_err" | sed -n 's/.* minor_tasks_walked=\([0-9]*\).*/\1/p' | head -1)
sq_skipped=$(echo "$sq_err" | sed -n 's/.* minor_tasks_skipped=\([0-9]*\).*/\1/p' | head -1)
if [ -z "$sq_walked" ] || [ -z "$sq_skipped" ] || [ "$sq_walked" -lt 10000 ]; then
    echo "FAIL idle queued tasks skipped (no slang-gc-stat line)"
    fail=1
elif [ $((sq_skipped * 2)) -lt "$sq_walked" ]; then
    echo "FAIL idle queued tasks skipped: $sq_skipped of $sq_walked, budget half"
    fail=1
else
    echo "PASS idle queued tasks skipped ($sq_skipped of $sq_walked)"
fi

# ---- argon2id kdf offload --------------------------------------------------
# On two workers the hashes go to kdf threads, so a ticker task keeps its
# pace while 64 of them are in flight. Derived inline it got ~5 turns.
echo "--- argon2id kdf offload (SLANG_WORKERS=2) ---"
# stdout only: GCC's LTO prints notes on stderr while compiling.
if ko_out=$(SLANG_WORKERS=2 ./slangc tests/crypto_offload/main.sl --run 2>/tmp/sl_kdf_offload.err) &&
   [ "$ko_out" = "kdf offload ok" ]; then
    echo "PASS argon2id kdf offload"
else
    echo "FAIL argon2id kdf offload: $ko_out $(tail -3 /tmp/sl_kdf_offload.err)"
    fail=1
fi

# ---- reactor work budget ---------------------------------------------------
# reactor_work_budget: 200 connections ping-pong 100 messages each with a
# deadline on every receive. Each wait used to be two epoll_ctl calls (ADD,
# failing with EEXIST, then MOD), and the reactor passed over all of its
# waiters before and after every batch of events. Budgets: at most 1.2
# registrations per wait, and passes over the waiters on at most a tenth
# of the reactor's iterations (none are due here).
echo "--- reactor work budget (SLANG_REACTOR_STAT) ---"
rwb_line=$(SLANG_WORKERS=2 SLANG_REACTOR_STAT=1 ./slangc tests/reactor_work_budget/main.sl \
           --run 2>&1 >/dev/null | grep -o 'parks=.*loops=[0-9]*')
rwb_parks=$(echo "$rwb_line" | sed -n 's/^parks=\([0-9]*\).*/\1/p')
rwb_regs=$(echo "$rwb_line" | sed -n 's/.*registrations=\([0-9]*\).*/\1/p')
rwb_scans=$(echo "$rwb_line" | sed -n 's/.*scans=\([0-9]*\).*/\1/p')
rwb_loops=$(echo "$rwb_line" | sed -n 's/.*loops=\([0-9]*\)$/\1/p')
if [ -z "$rwb_parks" ] || [ -z "$rwb_regs" ] || [ -z "$rwb_scans" ] || [ -z "$rwb_loops" ] ||
   [ "$rwb_parks" -lt 10000 ]; then
    echo "FAIL reactor work budget (no slang-reactor-stat line: $rwb_line)"
    fail=1
elif [ $((rwb_regs * 10)) -gt $((rwb_parks * 12)) ]; then
    echo "FAIL reactor work budget: $rwb_regs registrations for $rwb_parks waits, budget 1.2 each"
    fail=1
elif [ $((rwb_scans * 10)) -gt "$rwb_loops" ]; then
    echo "FAIL reactor work budget: $rwb_scans waiter passes in $rwb_loops reactor loops, budget a tenth"
    fail=1
else
    echo "PASS reactor work budget ($rwb_regs registrations for $rwb_parks waits, $rwb_scans passes in $rwb_loops loops)"
fi
# The same run on 4 workers: idle workers poll the reactor's set
# themselves (sl_net_worker_poll), so the reactor thread is rarely the one
# waking. Measured 619 reactor loops and 964 worker polls for 40297 waits;
# without worker polling the reactor looped once per 2-3 waits. Budget:
# at most one reactor loop per 4 waits, and worker polls happen at all.
# Linux only: kqueue keeps the reactor thread.
if [ "$(uname -s)" = Linux ]; then
    rwp_line=$(SLANG_WORKERS=4 SLANG_REACTOR_STAT=1 ./slangc tests/reactor_work_budget/main.sl \
               --run 2>&1 >/dev/null | grep -o 'parks=.*worker_polls=[0-9]*')
    rwp_parks=$(echo "$rwp_line" | sed -n 's/^parks=\([0-9]*\).*/\1/p')
    rwp_loops=$(echo "$rwp_line" | sed -n 's/.*loops=\([0-9]*\).*/\1/p')
    rwp_polls=$(echo "$rwp_line" | sed -n 's/.*worker_polls=\([0-9]*\)$/\1/p')
    if [ -z "$rwp_parks" ] || [ -z "$rwp_loops" ] || [ -z "$rwp_polls" ]; then
        echo "FAIL worker polling (no slang-reactor-stat line: $rwp_line)"
        fail=1
    elif [ "$rwp_polls" -eq 0 ] || [ $((rwp_loops * 4)) -gt "$rwp_parks" ]; then
        echo "FAIL worker polling: $rwp_loops reactor loops and $rwp_polls worker polls for $rwp_parks waits"
        fail=1
    else
        echo "PASS worker polling ($rwp_loops reactor loops, $rwp_polls worker polls for $rwp_parks waits)"
    fi
fi

# ---- reactor drains ---------------------------------------------------------
# net_dial_until, 60 times on one CPU. A worker polling in the reactor's
# place and the reactor thread can both be handed one level-triggered
# eventfd event; with the eventfds blocking, the second to drain it
# blocked in read() for good and the run hung (about one run in 80, so
# this catches it in about half of suite runs). Linux only: worker
# polling is.
if [ "$(uname -s)" = Linux ] && command -v taskset >/dev/null 2>&1; then
    echo "--- reactor drains (net_dial_until x60, one CPU) ---"
    rd_bin=/tmp/sl_reactor_drains
    if ./slangc tests/net_dial_until/main.sl -o "$rd_bin" >/dev/null 2>&1; then
        rd_bad=0
        for _ in $(seq 60); do
            if ! timeout 20 taskset -c 0 "$rd_bin" >/dev/null 2>&1; then
                rd_bad=$((rd_bad + 1))
            fi
        done
        if [ "$rd_bad" -ne 0 ]; then
            echo "FAIL reactor drains: $rd_bad of 60 runs hung or failed"
            fail=1
        else
            echo "PASS reactor drains (60 runs)"
        fi
    else
        echo "FAIL reactor drains (compile)"
        fail=1
    fi
    rm -f "$rd_bin"
fi

# ---- joined spawns run in place ---------------------------------------------
# spawn_join_local: spawn directly followed by join_wait, from 4 tasks on
# 8 workers, children that allocate, panic and run long. Those spawns used
# to be submitted as tasks: before sl_task_submit_copy_joined they woke
# sleeping workers about 17,500 times for 12,000 spawns, and 4 after it.
# Now they run in place on the spawner (sl_protect_run) and are never
# submitted: only the 4 outer tasks are. Budget: 16 submits.
echo "--- joined spawns run in place (SLANG_SCHED_STAT) ---"
rw_line=$(SLANG_WORKERS=8 SLANG_SCHED_STAT=1 ./slangc tests/spawn_join_local/main.sl \
          --run 2>&1 >/dev/null | grep -o 'submits=[0-9]*.*runnext_wakes=[0-9]*')
rw_submits=$(echo "$rw_line" | sed -n 's/^submits=\([0-9]*\).*/\1/p')
if [ -z "$rw_submits" ]; then
    echo "FAIL joined spawns run in place (no slang-sched-stat line: $rw_line)"
    fail=1
elif [ "$rw_submits" -gt 16 ]; then
    echo "FAIL joined spawns run in place: $rw_submits submits, budget 16"
    fail=1
else
    echo "PASS joined spawns run in place ($rw_submits submits for 12000 joins)"
fi

# Which spawns codegen runs in place (sl_protect_run): only one whose task
# does nothing before join_wait on it, since the spawner does not run
# again until the call is done. tests/spawn_join_marking has three such
# forms and four that must stay plain.
sjm_c="/tmp/sl_spawn_join_marking"
if ./slangc tests/spawn_join_marking/main.sl --keep-c -o "$sjm_c" >/dev/null 2>&1; then
    sjm_j=$(grep -o 'sl_protect_run(sl_spawn' "$sjm_c.gen.c" | wc -l | tr -d ' ')
    sjm_p=$(grep -o 'sl_task_submit_copy(sl_spawn' "$sjm_c.gen.c" | wc -l | tr -d ' ')
    if [ "$sjm_j" = 3 ] && [ "$sjm_p" = 4 ]; then
        echo "PASS joined spawn marking (3 joined, 4 plain)"
    else
        echo "FAIL joined spawn marking: $sjm_j joined, $sjm_p plain (want 3 and 4)"
        fail=1
    fi
else
    echo "FAIL joined spawn marking (compile)"
    fail=1
fi
rm -f "$sjm_c" "$sjm_c.gen.c"

# A leaf native (strings.has_prefix and the other pure readers, see
# native_is_leaf) is no collection point: its calls get no safepoint
# bracket, an allocating native next to them keeps its own.
lnc_c="/tmp/sl_leaf_native_calls"
if ./slangc tests/leaf_native_calls/main.sl --keep-c -o "$lnc_c" >/dev/null 2>&1; then
    lnc_leaf=$(grep -oE 'sl_rt_safepoint_enter\([^)]*\); [^;]*sl_strings_(has_prefix|has_suffix|contains|count|find|rfind|find_field)\(' "$lnc_c.gen.c" | wc -l | tr -d ' ')
    lnc_alloc=$(grep -oE 'sl_rt_safepoint_enter\([^)]*\); [^;]*sl_strings_to_upper\(' "$lnc_c.gen.c" | wc -l | tr -d ' ')
    if [ "$lnc_leaf" = 0 ] && [ "$lnc_alloc" = 1 ]; then
        echo "PASS leaf native calls unbracketed (allocating one kept)"
    else
        echo "FAIL leaf native calls: $lnc_leaf leaf calls bracketed, $lnc_alloc to_upper (want 0 and 1)"
        fail=1
    fi
else
    echo "FAIL leaf native calls (compile)"
    fail=1
fi
rm -f "$lnc_c" "$lnc_c.gen.c"

# A leaf slang function (compute_leaf_fns: no allocation, park, loop, or
# call but to builtins and leaf natives) gets unbracketed calls; functions
# that concatenate, loop, call slang, allocate, guard or index keep theirs.
lf_c="/tmp/sl_leaf_functions"
if ./slangc tests/leaf_functions/main.sl --keep-c -o "$lf_c" >/dev/null 2>&1; then
    lf_leaf=$(grep -oE 'sl_rt_safepoint_enter\([^)]*\); [^;]*sl_leaf_functions_put_str\(' "$lf_c.gen.c" | wc -l | tr -d ' ')
    lf_other=0
    for fn in concat loops calls_user allocs guards indexes; do
        n=$(grep -oE "sl_rt_safepoint_enter\\([^)]*\\); [^;]*sl_leaf_functions_${fn}\\(" "$lf_c.gen.c" | wc -l | tr -d ' ')
        lf_other=$((lf_other + n))
    done
    if [ "$lf_leaf" = 0 ] && [ "$lf_other" = 6 ]; then
        echo "PASS leaf functions unbracketed (6 non-leaf calls kept)"
    else
        echo "FAIL leaf functions: $lf_leaf put_str calls bracketed, $lf_other non-leaf (want 0 and 6)"
        fail=1
    fi
else
    echo "FAIL leaf functions (compile)"
    fail=1
fi
rm -f "$lf_c" "$lf_c.gen.c"

# A numeric `+` (i = i + 1, at + i, total + t[i]) no longer costs a loop
# its cheap path: it takes the leaf poll, or the scalar sampled yield when
# it carries no pointer, never a full per-iteration _sl_bp bracket. A str
# concat, a name rebound inside the loop, or an index of a str list on
# either side of `+` keeps that bracket.
llp_c="/tmp/sl_loop_leaf_plus"
if ./slangc tests/loop_leaf_plus/main.sl --keep-c -o "$llp_c" >/dev/null 2>&1; then
    llp_bad=""
    for fn in copy_at sum_compound range_sum varint_len float_acc concat_loop shadowed index_plus; do
        n=$(awk "/^static .*sl_loop_leaf_plus_${fn}\\(.*\\{\$/,/^}/" "$llp_c.gen.c" | grep -c 'sl_safepoint _sl_bp[0-9]*;')
        case "$fn" in
            concat_loop|shadowed|index_plus) want=1 ;;
            *) want=0 ;;
        esac
        [ "$n" = "$want" ] || llp_bad="$llp_bad $fn(brackets=$n)"
    done
    if [ -z "$llp_bad" ]; then
        echo "PASS numeric + keeps loops off the per-iteration bracket (5 cheap, 3 bracketed)"
    else
        echo "FAIL numeric + loops:$llp_bad (want 0 for the first five, 1 for the rest)"
        fail=1
    fi
else
    echo "FAIL numeric + loops (compile)"
    fail=1
fi
rm -f "$llp_c" "$llp_c.gen.c"

# ---- worker count from a cgroup CPU quota (Linux) ---------------------------
# The pool takes one worker per CPU the affinity mask allows, lowered to
# a cgroup CPU quota rounded up (at least 2), as Go 1.25 sizes GOMAXPROCS.
# Fake cgroup trees through SLANG_TEST_CGROUP_PROC / SLANG_TEST_CGROUP_FS;
# expectations are relative to this machine's own affinity count.
if [ "$(uname -s)" = Linux ]; then
    echo "--- worker count from a cgroup CPU quota ---"
    cg_dir=$(mktemp -d)
    cg_bin="$cg_dir/prog"
    mkdir -p "$cg_dir/src"
    printf 'println("ok");\n' >"$cg_dir/src/main.sl"
    ./slangc "$cg_dir/src/main.sl" -o "$cg_bin" >/dev/null 2>&1
    cg_n=$(nproc)
    cg_min() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; }
    # case: name, /proc/self/cgroup line, files to write (path=content ...)
    cg_case() {
        name=$1; want=$2; proc=$3; shift 3
        root="$cg_dir/$name"
        mkdir -p "$root/fs"
        printf '%s\n' "$proc" >"$root/cgroup"
        for kv in "$@"; do
            f=${kv%%=*}; v=${kv#*=}
            mkdir -p "$(dirname "$root/fs/$f")"
            printf '%s\n' "$v" >"$root/fs/$f"
        done
        got=$(env SLANG_TEST_CGROUP_PROC="$root/cgroup" \
              SLANG_TEST_CGROUP_FS="$root/fs" SLANG_SCHED_STAT=1 \
              ${CG_WORKERS:+SLANG_WORKERS=$CG_WORKERS} "$cg_bin" 2>&1 >/dev/null |
              sed -n 's/.*workers=\([0-9]*\).*/\1/p')
        if [ "$got" = "$want" ]; then
            echo "PASS cgroup workers $name ($got)"
        else
            echo "FAIL cgroup workers $name: got '$got', want $want"
            fail=1
        fi
    }
    cg_case v2_leaf "$(cg_min 2 "$cg_n")" "0::/a/b" \
        "a/b/cpu.max=150000 100000" "a/cpu.max=max 100000"
    cg_case v2_parent_tighter "$(cg_min 3 "$cg_n")" "0::/a/b" \
        "a/b/cpu.max=max 100000" "a/cpu.max=300000 100000"
    cg_case v2_unlimited "$cg_n" "0::/a" "a/cpu.max=max 100000"
    cg_case v2_half_cpu "$(cg_min 2 "$cg_n")" "0::/a" "a/cpu.max=50000 100000"
    cg_case v1_container_root "$(cg_min 3 "$cg_n")" \
        "4:cpu,cpuacct:/docker/abc" \
        "cpu,cpuacct/cpu.cfs_quota_us=300000" \
        "cpu,cpuacct/cpu.cfs_period_us=100000"
    cg_case v1_unlimited "$cg_n" "4:cpu,cpuacct:/" \
        "cpu,cpuacct/cpu.cfs_quota_us=-1" \
        "cpu,cpuacct/cpu.cfs_period_us=100000"
    cg_case v2_garbage "$cg_n" "0::/a" "a/cpu.max=lots 100000"
    cg_case v2_dotdot "$cg_n" "0::/a/../b" "b/cpu.max=100000 100000"
    CG_WORKERS=5 cg_case override 5 "0::/a" "a/cpu.max=100000 100000"
    rm -rf "$cg_dir"
fi

# ---- promotion budgets ------------------------------------------------------
# Objects promoted to the old generation, as a share of all allocations,
# for request-shaped workloads whose garbage must die young.
#   gc_promotion_budget  decode a 2,000-item body and walk it, 150 times.
#                        Was 30.7% promoted (one survival promoted, so a
#                        minor mid-walk promoted the whole tree); 0.28% with
#                        promotion after two survivals (fix-gc.md 1.2).
#   gc_chan_promotion_budget  100,000 short-lived values through an old
#                        channel. Was 3.7% of all allocations (93% of the
#                        values): a received value's slot kept its pointer and
#                        every slot was traced; ~0 now (slots cleared on
#                        receive, only queued values traced).
echo "--- promotion budgets (SLANG_GC_STAT) ---"
promo_bad=0
for spec in gc_promotion_budget:1 gc_chan_promotion_budget:1; do
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
# Growth depends on the measured pause share, so an end-to-end workload can
# legitimately stay at the base on a faster runner. The runtime test covers
# growth, hysteresis, shrink, and cap with controlled samples. Here, check
# that both workloads report an in-range nursery and cheap minors stay small.
# nursery_threshold= is its size at exit.
echo "--- nursery adaptation (SLANG_GC_STAT) ---"
nur_ad_bad=0
for spec in gc_promotion_budget:bounded gc_nursery_small:small; do
    name=${spec%%:*}
    want=${spec#*:}
    size=$(SLANG_GC_STAT=1 ./slangc "tests/$name/main.sl" --run 2>&1 >/dev/null |
           sed -n 's/^slang-gc-stat collects=.* nursery_threshold=\([0-9]*\).*/\1/p')
    if [ -z "$size" ]; then
        echo "FAIL nursery adaptation $name (no slang-gc-stat line)"
        nur_ad_bad=1; fail=1
    elif [ "$want" = bounded ] && \
         { [ "$size" -lt 524288 ] || [ "$size" -gt 16777216 ]; }; then
        echo "FAIL nursery adaptation $name: $size bytes outside 512 KB..16 MB"
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
stwline=$(SLANG_WORKERS=4 SLANG_GC_STAT=1 ./slangc tests/gc_stw_sleep/main.sl --run 2>&1 >/dev/null |
      sed -n 's/^slang-gc-stat stw_waits=\([0-9]*\) stw_sleeps=\([0-9]*\) sweep_helps=\([0-9]*\) mark_helps=\([0-9]*\)$/\1 \2 \3 \4/p')
markhelps=${stwline##* }
stwline=${stwline% *}
stw=${stwline% *}
if [ -z "$stwline" ]; then
    echo "FAIL stopped threads sleep (no slang-gc-stat stw line)"
    fail=1
elif [ "${stw#* }" -eq 0 ]; then
    echo "FAIL stopped threads sleep: waits/sleeps $stw"
    fail=1
else
    echo "PASS stopped threads sleep (waits/sleeps $stw)"
fi

# ---- stopped threads help sweep ----------------------------------------------
# The same pauses: a stopped thread joins the collector's sweep job
# (sl_gc_job_help) and sweeps pages alongside it, instead of waiting for
# it to sweep every worker's pages alone (todo.md R4).
echo "--- stopped threads help sweep (SLANG_GC_STAT) ---"
helps=${stwline##* }
if [ -z "$stwline" ]; then
    echo "FAIL stopped threads help sweep (no sweep_helps in the stw line)"
    fail=1
elif [ "$helps" -eq 0 ]; then
    echo "FAIL stopped threads help sweep: sweep_helps=0"
    fail=1
else
    echo "PASS stopped threads help sweep (sweep_helps=$helps)"
fi

# ---- stopped threads help mark ------------------------------------------------
# A stopped thread joins the minor's mark job and marks root-bearing tasks
# and remembered entries alongside the collector, each into its own slot
# (todo.md R4, parallel mark) -- once there are enough of them to be worth
# waking it (SL_GC_MARK_PARALLEL_MIN): gc_many_tasks parks 300.
echo "--- stopped threads help mark (SLANG_GC_STAT) ---"
stwline=$(SLANG_WORKERS=4 SLANG_GC_STAT=1 ./slangc tests/gc_many_tasks/main.sl --run 2>&1 >/dev/null |
      sed -n 's/^slang-gc-stat stw_waits=\([0-9]*\) stw_sleeps=\([0-9]*\) sweep_helps=\([0-9]*\) mark_helps=\([0-9]*\)$/\1 \2 \3 \4/p')
markhelps=${stwline##* }
if [ -z "$stwline" ]; then
    echo "FAIL stopped threads help mark (no mark_helps in the stw line)"
    fail=1
elif [ "$markhelps" -eq 0 ]; then
    echo "FAIL stopped threads help mark: mark_helps=0"
    fail=1
else
    echo "PASS stopped threads help mark (mark_helps=$markhelps)"
fi

# ---- stopped threads help a major's mark ---------------------------------------
# A major's mark is split the same way as a minor's (todo.md R4, parallel
# mark step 4). At a 16KB major threshold every collection is a major;
# with 300 parked tasks to mark, stopped threads must join them.
echo "--- stopped threads help a major's mark (SLANG_GC_STAT) ---"
mjhelps=$(SLANG_WORKERS=4 SLANG_GC_STAT=1 SLANG_GC_THRESHOLD_KB=16 ./slangc tests/gc_many_tasks/main.sl --run 2>&1 >/dev/null |
          sed -n 's/.* major_mark_helps=\([0-9]*\).*/\1/p')
if [ -z "$mjhelps" ]; then
    echo "FAIL stopped threads help a major's mark (no major_mark_helps)"
    fail=1
elif [ "$mjhelps" -eq 0 ]; then
    echo "FAIL stopped threads help a major's mark: major_mark_helps=0"
    fail=1
else
    echo "PASS stopped threads help a major's mark (major_mark_helps=$mjhelps)"
fi

# ---- minors skip long-idle parked tasks ---------------------------------------
# A parked task that two minors have scanned since it last ran holds only
# old objects, so later minors leave its roots out (sl_gc_root_units_build;
# fix-gc.md 1.6). gc_idle_tasks parks 200 tasks across many minors and
# checks what they hold when woken; SLANG_GC_STAT must show skips.
echo "--- minors skip idle parked tasks (SLANG_GC_STAT) ---"
skipped=$(SLANG_WORKERS=4 SLANG_GC_STAT=1 ./slangc tests/gc_idle_tasks/main.sl --run 2>&1 >/dev/null |
          sed -n 's/.* minor_tasks_skipped=\([0-9]*\).*/\1/p')
if [ -z "$skipped" ]; then
    echo "FAIL minors skip idle parked tasks (no minor_tasks_skipped)"
    fail=1
elif [ "$skipped" -eq 0 ]; then
    echo "FAIL minors skip idle parked tasks: none skipped"
    fail=1
else
    echo "PASS minors skip idle parked tasks ($skipped skipped)"
fi

# ---- pointer-free containers are not scanned ---------------------------------
# A list or map whose elements provably hold no GC pointer ([int], [float],
# enums, value structs of those) is built with SL_ELEM_NOPTR, and the
# collector skips its elements; it used to offer every word to mark, a
# lookup each, which batch's million-entry [int] tables paid on every
# major (fix-gc.md 1.8). The flag is the compiler's, so check its output.
echo "--- pointer-free containers (generated C) ---"
pfdir=$(mktemp -d)
cp tests/gc_pointer_free/main.sl "$pfdir/main.sl"
if ! ./slangc "$pfdir/main.sl" -o "$pfdir/prog" --keep-c >/dev/null 2>&1; then
    echo "FAIL pointer-free containers (did not compile)"
    fail=1
else
    pfc="$pfdir/prog.gen.c"
    missing=""
    for want in 'sl_arr_new(sizeof(long long), 2)' 'sl_arr_new(sizeof(double), 2)' \
                'sl_arr_new(sizeof(int32_t), 2)' 'sl_arr_new(sizeof(const char *), 1)' \
                'sizeof(long long), sizeof(long long), 0, 2, 2)'; do
        grep -qF "$want" "$pfc" || missing="$missing [$want]"
    done
    if [ -n "$missing" ]; then
        echo "FAIL pointer-free containers: generated C lacks$missing"
        fail=1
    else
        echo "PASS pointer-free containers"
    fi
fi
rm -rf "$pfdir"

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
# One full compile with optimization and _FORTIFY_SOURCE, as slangc's own
# -O3 build is on Ubuntu, where glibc then marks read/write
# warn_unused_result. Those warnings come from the optimizer, which
# -fsyntax-only never runs, and from runtime code every program shares,
# so one program that uses the reactor and the resolver covers them.
if ./slangc tests/net_deadline_many/main.sl --emit-c >/dev/null 2>&1; then
    diag=$(cc -c -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -o /dev/null \
           main.gen.c 2>&1 | grep 'warning:')
    if [ -n "$diag" ]; then
        w=$(printf '%s\n' "$diag" | wc -l | tr -d ' ')
        echo "FAIL net_deadline_many ($w warning(s) with -O2 -D_FORTIFY_SOURCE=2)"
        printf '%s\n' "$diag" | head -3
        warned=$((warned + w))
        fail=1
    fi
fi
rm -f main.gen.c
if [ "$warned" -eq 0 ]; then
    echo "PASS generated C is warning-free"
fi

if [ "$fail" -ne 0 ]; then
    echo "some tests failed"
    exit 1
fi
echo "all tests passed"
