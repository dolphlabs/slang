#!/bin/sh
# Alternate-order compute bench: slang / Go / C / Rust / Java / Zig / C#.
# Usage: CC_TASKS=200 CC_WORK=8000 CC_ALLOC=50 ./bench/run_compute.sh
# Missing toolchains are skipped. Prints compile times, RESULT lines, medians.

set -eu
cd "$(dirname "$0")/.."

export PATH="${HOME}/.local/bin:${HOME}/.dotnet:${PATH:-/usr/bin}"
export DOTNET_ROOT="${DOTNET_ROOT:-${HOME}/.dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

TASKS="${CC_TASKS:-200}"
WORK="${CC_WORK:-8000}"
ALLOC="${CC_ALLOC:-50}"
ROUNDS="${CC_ROUNDS:-3}"
export CC_TASKS="$TASKS" CC_WORK="$WORK" CC_ALLOC="$ALLOC"

SL_BIN=/tmp/sl_bench_compute
SL_ARENA_BIN=/tmp/sl_bench_compute_arena
GO_BIN=/tmp/go_bench_compute
C_BIN=/tmp/c_bench_compute
RS_BIN=/tmp/rs_bench_compute
JAVA_DIR=/tmp/java_bench_compute
JAVA_WRAP=/tmp/java_bench_compute.sh
ZIG_BIN=/tmp/zig_bench_compute
CS_DIR=/tmp/cs_bench_compute
CS_BIN=/tmp/cs_bench_compute/Compute
OUT_DIR=/tmp/slang_phase_e_compute
mkdir -p "$OUT_DIR"
: >"$OUT_DIR/runs.tsv"
: >"$OUT_DIR/skipped.txt"

if [ ! -x ./slangc ]; then
    make slangc
fi

time_sec() {
    tf="$OUT_DIR/time.$$"
    if ! /usr/bin/time -f '%e' -o "$tf" "$@" >/dev/null; then
        rm -f "$tf"
        return 1
    fi
    tail -n 1 "$tf"
    rm -f "$tf"
}

skip() {
    echo "skip $1: $2" | tee -a "$OUT_DIR/skipped.txt"
}

HAVE_SL=0
HAVE_SLA=0
HAVE_GO=0
HAVE_C=0
HAVE_RS=0
HAVE_JAVA=0
HAVE_ZIG=0
HAVE_CS=0

echo "=== compile ==="
if c_sl=$(time_sec ./slangc stress_test/programs/concurrent_compute/main.sl -o "$SL_BIN"); then
    HAVE_SL=1
else
    skip slang_gc "slangc failed"
    c_sl="fail"
fi
if c_sla=$(time_sec ./slangc bench/compute/arena.sl -o "$SL_ARENA_BIN"); then
    HAVE_SLA=1
else
    skip slang_arena "slangc failed"
    c_sla="fail"
fi
if command -v go >/dev/null 2>&1 && c_go=$(time_sec go build -o "$GO_BIN" bench/compute/main.go); then
    HAVE_GO=1
else
    skip go "go missing or build failed"
    c_go="fail"
fi
if c_cc=$(time_sec cc -O3 -std=c11 -D_GNU_SOURCE bench/compute/main.c -lpthread -o "$C_BIN"); then
    HAVE_C=1
else
    skip c "cc failed"
    c_cc="fail"
fi
if command -v rustc >/dev/null 2>&1 && c_rs=$(time_sec rustc --edition 2021 -C opt-level=3 bench/compute/main.rs -o "$RS_BIN"); then
    HAVE_RS=1
else
    skip rust "rustc missing or build failed"
    c_rs="fail"
fi
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    mkdir -p "$JAVA_DIR"
    if c_java=$(time_sec javac -d "$JAVA_DIR" bench/compute/Compute.java); then
        printf '#!/bin/sh\nexec java -cp %s Compute\n' "$JAVA_DIR" >"$JAVA_WRAP"
        chmod +x "$JAVA_WRAP"
        HAVE_JAVA=1
    else
        skip java "javac failed"
        c_java="fail"
    fi
else
    skip java "javac/java missing"
    c_java="fail"
fi
if command -v zig >/dev/null 2>&1 && c_zig=$(time_sec zig build-exe -O ReleaseFast -femit-bin="$ZIG_BIN" --cache-dir /tmp/zig-cache bench/compute/main.zig); then
    HAVE_ZIG=1
else
    skip zig "zig missing or build failed"
    c_zig="fail"
fi
if command -v dotnet >/dev/null 2>&1; then
    dotnet restore bench/compute/cs/Compute.csproj >/dev/null
    if c_cs=$(time_sec dotnet publish bench/compute/cs/Compute.csproj -c Release -o "$CS_DIR" --no-restore); then
        HAVE_CS=1
    else
        skip csharp "dotnet publish failed"
        c_cs="fail"
    fi
else
    skip csharp "dotnet missing"
    c_cs="fail"
fi

printf 'compile_s slang_gc=%s slang_arena=%s go=%s cc_O3=%s rustc_O3=%s javac=%s zig_ReleaseFast=%s dotnet_publish=%s\n' \
    "$c_sl" "$c_sla" "$c_go" "$c_cc" "$c_rs" "$c_java" "$c_zig" "$c_cs"
echo "$c_sl $c_sla $c_go $c_cc $c_rs $c_java $c_zig $c_cs" >"$OUT_DIR/compile.txt"

LANGS=""
[ "$HAVE_SL" -eq 1 ] && LANGS="$LANGS slang"
[ "$HAVE_GO" -eq 1 ] && LANGS="$LANGS go"
[ "$HAVE_C" -eq 1 ] && LANGS="$LANGS c"
[ "$HAVE_RS" -eq 1 ] && LANGS="$LANGS rust"
[ "$HAVE_JAVA" -eq 1 ] && LANGS="$LANGS java"
[ "$HAVE_ZIG" -eq 1 ] && LANGS="$LANGS zig"
[ "$HAVE_CS" -eq 1 ] && LANGS="$LANGS csharp"
LANGS=$(echo "$LANGS" | sed 's/^ *//')

bin_for() {
    case $1 in
        slang) echo "$SL_BIN" ;;
        slang_arena) echo "$SL_ARENA_BIN" ;;
        go) echo "$GO_BIN" ;;
        c) echo "$C_BIN" ;;
        rust) echo "$RS_BIN" ;;
        java) echo "$JAVA_WRAP" ;;
        zig) echo "$ZIG_BIN" ;;
        csharp) echo "$CS_BIN" ;;
    esac
}

run_one() {
    name=$1
    bin=$(bin_for "$name")
    out="/tmp/${name}_bench_compute.out"
    if [ ! -x "$bin" ]; then
        echo "$name SKIP missing binary $bin"
        return 0
    fi
    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l "$bin" >"$out" 2>"$out.time" || true
        rss_b=$(awk '/maximum resident set size/ { print $1; exit }' "$out.time" || true)
        if [ -n "${rss_b:-}" ]; then
            rss=$((rss_b / 1024))
        else
            rss="?"
        fi
    else
        /usr/bin/time -f 'RSS_KB=%M' "$bin" >"$out" 2>"$out.time" || true
        rss=$(sed -n 's/^RSS_KB=//p' "$out.time" | tail -n 1)
        rss=${rss:-?}
    fi
    if grep -q 'Command terminated by signal' "$out.time" 2>/dev/null; then
        sig=$(sed -n 's/.*signal //p' "$out.time" | head -n 1)
        printf '%s CRASH signal=%s rss_kb=%s\n' "$name" "${sig:-?}" "${rss:-?}"
        printf '%s\tcrash\t%s\t\n' "$name" "${rss:-}" >>"$OUT_DIR/runs.tsv"
        if [ "$name" = slang ]; then
            echo "-- slang crash hint --"
            dmesg 2>/dev/null | tail -n 20 || true
            cat "$out.time" || true
        fi
        return 0
    fi
    wall=$(grep '^RESULT' "$out" | sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p' || true)
    tps=$(grep '^RESULT' "$out" | sed -n 's/.*tasks_per_sec=\([0-9]*\).*/\1/p' || true)
    primes=$(grep '^RESULT' "$out" | sed -n 's/.*total_primes=\([0-9]*\).*/\1/p' || true)
    alloc=$(grep '^RESULT' "$out" | sed -n 's/.*total_alloc_sum=\([0-9]*\).*/\1/p' || true)
    printf '%s wall_ms=%s rss_kb=%s tasks_per_sec=%s total_primes=%s total_alloc_sum=%s\n' \
        "$name" "${wall:-?}" "${rss:-?}" "${tps:-?}" "${primes:-?}" "${alloc:-?}"
    printf '%s\t%s\t%s\t%s\n' "$name" "${wall:-}" "${rss:-}" "${tps:-}" >>"$OUT_DIR/runs.tsv"
}

rotate_langs() {
    r=$1
    set -- $LANGS
    n=$#
    if [ "$n" -eq 0 ]; then
        return
    fi
    shift_n=$(( (r - 1) % n ))
    i=0
    while [ "$i" -lt "$shift_n" ]; do
        first=$1
        shift
        set -- "$@" "$first"
        i=$((i + 1))
    done
    if [ $((r % 2)) -eq 0 ]; then
        rev=""
        for x in "$@"; do
            rev="$x $rev"
        done
        echo "$rev"
    else
        echo "$@"
    fi
}

echo "compute bench tasks=$TASKS work=$WORK alloc=$ALLOC rounds=$ROUNDS"
echo "langs=$LANGS"
echo "order rotates each round"
r=1
while [ "$r" -le "$ROUNDS" ]; do
    echo "-- round $r --"
    for name in $(rotate_langs "$r"); do
        run_one "$name"
    done
    r=$((r + 1))
done

if [ "$HAVE_SLA" -eq 1 ]; then
    echo "-- slang arena (no list/map GC; extra, not vs Go maps) --"
    run_one slang_arena
fi

echo "-- medians (wall_ms, rss_kb, tasks_per_sec) --"
awk -F '\t' '
function med(a, n,    s, i, j, t) {
    for (i = 1; i <= n; i++) s[i] = a[i]
    for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
            if (s[j] + 0 < s[i] + 0) { t = s[i]; s[i] = s[j]; s[j] = t }
    if (n < 1) return 0
    if (n % 2) return s[int(n / 2) + 1]
    return (s[n / 2] + s[n / 2 + 1]) / 2
}
$2 == "crash" { crash[$1]++; next }
{
    n[$1]++
    w[$1, n[$1]] = $2
    r[$1, n[$1]] = $3
    t[$1, n[$1]] = $4
}
END {
    for (k in n) {
        nw = n[k]
        split("", aw); split("", ar); split("", at)
        for (i = 1; i <= nw; i++) { aw[i] = w[k, i]; ar[i] = r[k, i]; at[i] = t[k, i] }
        extra = crash[k] ? sprintf(" crashes=%d", crash[k]) : ""
        printf "%s wall_ms=%s rss_kb=%s tasks_per_sec=%s n=%d%s\n", \
            k, med(aw, nw), med(ar, nw), med(at, nw), nw, extra
    }
    for (k in crash) if (!(k in n))
        printf "%s CRASH all %d runs\n", k, crash[k]
}
' "$OUT_DIR/runs.tsv"
