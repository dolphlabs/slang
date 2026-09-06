#!/bin/sh
# Alternate-order HTTP bench: slang / Go / C / Rust / Java / Zig / C#.
# Usage: HTTP_ROUNDS=3 HTTP_DUR=10s ./bench/run_http.sh
# Missing toolchains are skipped.

set -eu
cd "$(dirname "$0")/.."

export PATH="${HOME}/.local/bin:${HOME}/.dotnet:${PATH:-/usr/bin}"
export DOTNET_ROOT="${DOTNET_ROOT:-${HOME}/.dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

ROUNDS="${HTTP_ROUNDS:-3}"
DUR="${HTTP_DUR:-10s}"
CONCS="${HTTP_CONCS:-50 200}"
SL_PORT="${HTTP_SL_PORT:-18180}"
GO_PORT="${HTTP_GO_PORT:-18181}"
C_PORT="${HTTP_C_PORT:-18182}"
RS_PORT="${HTTP_RS_PORT:-18183}"
JAVA_PORT="${HTTP_JAVA_PORT:-18184}"
ZIG_PORT="${HTTP_ZIG_PORT:-18185}"
CS_PORT="${HTTP_CS_PORT:-18186}"
OUT_DIR=/tmp/slang_phase_e_http
mkdir -p "$OUT_DIR"
: >"$OUT_DIR/runs.tsv"
: >"$OUT_DIR/skipped.txt"

SL_BIN=/tmp/sl_bench_http
GO_BIN=/tmp/go_bench_http
C_BIN=/tmp/c_bench_http
LG_BIN=/tmp/http_loadgen
RS_DIR=bench/http/rust
RS_BIN="$RS_DIR/target/release/http_bench"
JAVA_DIR=/tmp/java_bench_http
JAVA_WRAP=/tmp/java_bench_http.sh
ZIG_BIN=/tmp/zig_bench_http
CS_DIR=/tmp/cs_bench_http
CS_BIN=/tmp/cs_bench_http/HttpBench

if [ ! -x ./slangc ]; then
    make slangc
fi

skip() {
    echo "skip $1: $2" | tee -a "$OUT_DIR/skipped.txt"
}

kill_bin() {
    name=$1
    pkill -KILL -f "$name" 2>/dev/null || true
}

kill_port() {
    p=$1
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    fi
}

HAVE_SL=0
HAVE_GO=0
HAVE_C=0
HAVE_RS=0
HAVE_JAVA=0
HAVE_ZIG=0
HAVE_CS=0

cleanup() {
    [ "$HAVE_SL" -eq 1 ] && kill_bin "$SL_BIN"
    [ "$HAVE_GO" -eq 1 ] && kill_bin "$GO_BIN"
    [ "$HAVE_C" -eq 1 ] && kill_bin "$C_BIN"
    [ "$HAVE_RS" -eq 1 ] && kill_bin "$RS_BIN"
    [ "$HAVE_JAVA" -eq 1 ] && kill_bin "java -cp $JAVA_DIR HttpBench"
    [ "$HAVE_ZIG" -eq 1 ] && kill_bin "$ZIG_BIN"
    [ "$HAVE_CS" -eq 1 ] && kill_bin "$CS_BIN"
    kill_port "$SL_PORT"
    kill_port "$GO_PORT"
    kill_port "$C_PORT"
    kill_port "$RS_PORT"
    kill_port "$JAVA_PORT"
    kill_port "$ZIG_PORT"
    kill_port "$CS_PORT"
}
trap cleanup EXIT INT TERM
cleanup

time_sec() {
    tf="$OUT_DIR/time.$$"
    if ! /usr/bin/time -f '%e' -o "$tf" "$@" >/dev/null; then
        rm -f "$tf"
        return 1
    fi
    tail -n 1 "$tf"
    rm -f "$tf"
}

echo "=== compile ==="
if c_sl=$(time_sec ./slangc bench/http/main.sl -o "$SL_BIN"); then
    HAVE_SL=1
else
    skip slang "slangc failed"
    c_sl="fail"
fi
if command -v go >/dev/null 2>&1 && c_go=$(time_sec go build -o "$GO_BIN" bench/http/main.go); then
    HAVE_GO=1
else
    skip go "go missing or build failed"
    c_go="fail"
fi
if c_cc=$(time_sec cc -O3 -flto -std=c11 bench/http/main.c -lpthread -o "$C_BIN"); then
    HAVE_C=1
else
    skip c "cc failed"
    c_cc="fail"
fi
if command -v go >/dev/null 2>&1; then
    go build -o "$LG_BIN" bench/http/loadgen.go
fi
c_rs="fail"
if command -v cargo >/dev/null 2>&1; then
    (
        cd "$RS_DIR"
        cargo fetch
        cargo clean
    )
    if c_rs=$(time_sec cargo build --release --manifest-path "$RS_DIR/Cargo.toml"); then
        HAVE_RS=1
    else
        skip rust "cargo build failed"
        c_rs="fail"
    fi
else
    skip rust "cargo missing"
fi
c_java="fail"
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    mkdir -p "$JAVA_DIR"
    if c_java=$(time_sec javac -d "$JAVA_DIR" bench/http/HttpBench.java); then
        printf '#!/bin/sh\nexec java -cp %s HttpBench\n' "$JAVA_DIR" >"$JAVA_WRAP"
        chmod +x "$JAVA_WRAP"
        HAVE_JAVA=1
    else
        skip java "javac failed"
        c_java="fail"
    fi
else
    skip java "javac/java missing"
fi
c_zig="fail"
if command -v zig >/dev/null 2>&1 && c_zig=$(time_sec zig build-exe -O ReleaseFast -femit-bin="$ZIG_BIN" --cache-dir /tmp/zig-cache bench/http/main.zig); then
    HAVE_ZIG=1
else
    skip zig "zig missing or build failed"
    c_zig="fail"
fi
c_cs="fail"
if command -v dotnet >/dev/null 2>&1; then
    dotnet restore bench/http/cs/HttpBench.csproj >/dev/null
    if c_cs=$(time_sec dotnet publish bench/http/cs/HttpBench.csproj -c Release -o "$CS_DIR" --no-restore); then
        HAVE_CS=1
    else
        skip csharp "dotnet publish failed"
        c_cs="fail"
    fi
else
    skip csharp "dotnet missing"
fi

printf 'compile_s slang=%s go=%s cc_O3_lto=%s rust_axum_release=%s javac=%s zig_ReleaseFast=%s dotnet_publish=%s\n' \
    "$c_sl" "$c_go" "$c_cc" "$c_rs" "$c_java" "$c_zig" "$c_cs"
echo "$c_sl $c_go $c_cc $c_rs $c_java $c_zig $c_cs" >"$OUT_DIR/compile.txt"

LANGS=""
[ "$HAVE_SL" -eq 1 ] && LANGS="$LANGS slang"
[ "$HAVE_GO" -eq 1 ] && LANGS="$LANGS go"
[ "$HAVE_C" -eq 1 ] && LANGS="$LANGS c"
[ "$HAVE_RS" -eq 1 ] && LANGS="$LANGS rust"
[ "$HAVE_JAVA" -eq 1 ] && LANGS="$LANGS java"
[ "$HAVE_ZIG" -eq 1 ] && LANGS="$LANGS zig"
[ "$HAVE_CS" -eq 1 ] && LANGS="$LANGS csharp"
LANGS=$(echo "$LANGS" | sed 's/^ *//')

nproc=$(nproc 2>/dev/null || echo 4)
wrk_threads() {
    c=$1
    t=$nproc
    if [ "$t" -gt "$c" ]; then
        t=$c
    fi
    echo "$t"
}

rss_kb() {
    pid=$1
    awk '/^VmHWM:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || echo "?"
}

wait_http() {
    port=$1
    i=0
    while [ "$i" -lt 80 ]; do
        if curl -sS -o /tmp/http_probe.body --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    return 1
}

to_ms() {
    awk -v s="$1" '
    BEGIN {
        if (s ~ /us$/) { gsub(/us/, "", s); print s/1000; exit }
        if (s ~ /ms$/) { gsub(/ms/, "", s); print s+0; exit }
        if (s ~ /s$/)  { gsub(/s/, "", s); print s*1000; exit }
        print s+0
    }'
}

run_load() {
    port=$1
    conc=$2
    out=$3
    url="http://127.0.0.1:${port}/"
    if command -v wrk >/dev/null 2>&1; then
        t=$(wrk_threads "$conc")
        wrk -t"$t" -c"$conc" -d"$DUR" --latency "$url" >"$out" 2>&1 || true
        rps=$(awk '/^Requests\/sec:/ { print $2 }' "$out")
        p50s=$(awk '/^[[:space:]]*50%/ { print $2; exit }' "$out")
        p99s=$(awk '/^[[:space:]]*99%/ { print $2; exit }' "$out")
        p50=$(to_ms "${p50s:-0}")
        p99=$(to_ms "${p99s:-0}")
        err=$(awk '
            /Socket errors:/ {
                s=$0; gsub(/[^0-9 ]/, " ", s);
                n=split(s, a, " ");
                t=0; for (i=1;i<=n;i++) t+=a[i];
                print t; found=1
            }
            /Non-2xx or 3xx responses:/ { e=$NF }
            END { if (!found) print 0+e }
        ' "$out")
    else
        "$LG_BIN" -url "$url" -c "$conc" -d "$DUR" >"$out" 2>&1 || true
        rps=$(sed -n 's/.*rps=\([0-9.]*\).*/\1/p' "$out")
        p50=$(sed -n 's/.*p50_ms=\([0-9.]*\).*/\1/p' "$out")
        p99=$(sed -n 's/.*p99_ms=\([0-9.]*\).*/\1/p' "$out")
        err=$(sed -n 's/.*errors=\([0-9]*\).*/\1/p' "$out")
    fi
    printf '%s %s %s %s' "${rps:-0}" "${p50:-0}" "${p99:-0}" "${err:-0}"
}

start_named() {
    name=$1
    case $name in
        slang)
            kill_port "$SL_PORT"
            : >"$OUT_DIR/slang.log"
            if command -v stdbuf >/dev/null 2>&1; then
                HTTP_PORT="$SL_PORT" stdbuf -oL -eL "$SL_BIN" >"$OUT_DIR/slang.log" 2>&1 &
            else
                HTTP_PORT="$SL_PORT" "$SL_BIN" >"$OUT_DIR/slang.log" 2>&1 &
            fi
            echo $!
            ;;
        go)
            kill_port "$GO_PORT"
            HTTP_PORT="$GO_PORT" "$GO_BIN" >"$OUT_DIR/go.log" 2>&1 &
            echo $!
            ;;
        c)
            kill_port "$C_PORT"
            HTTP_PORT="$C_PORT" "$C_BIN" >"$OUT_DIR/c.log" 2>&1 &
            echo $!
            ;;
        rust)
            kill_port "$RS_PORT"
            HTTP_PORT="$RS_PORT" "$RS_BIN" >"$OUT_DIR/rust.log" 2>&1 &
            echo $!
            ;;
        java)
            kill_port "$JAVA_PORT"
            HTTP_PORT="$JAVA_PORT" "$JAVA_WRAP" >"$OUT_DIR/java.log" 2>&1 &
            echo $!
            ;;
        zig)
            kill_port "$ZIG_PORT"
            HTTP_PORT="$ZIG_PORT" "$ZIG_BIN" >"$OUT_DIR/zig.log" 2>&1 &
            echo $!
            ;;
        csharp)
            kill_port "$CS_PORT"
            HTTP_PORT="$CS_PORT" "$CS_BIN" >"$OUT_DIR/csharp.log" 2>&1 &
            echo $!
            ;;
    esac
}

port_for() {
    name=$1
    case $name in
        slang) echo "$SL_PORT" ;;
        go) echo "$GO_PORT" ;;
        c) echo "$C_PORT" ;;
        rust) echo "$RS_PORT" ;;
        java) echo "$JAVA_PORT" ;;
        zig) echo "$ZIG_PORT" ;;
        csharp) echo "$CS_PORT" ;;
    esac
}

run_server() {
    name=$1
    conc=$2
    round=$3
    pid=$(start_named "$name")
    port=$(port_for "$name")
    if ! wait_http "$port"; then
        echo "$name conc=$conc FAIL not ready (port=${port:-?})"
        if [ -f "$OUT_DIR/${name}.log" ]; then
            tail -n 20 "$OUT_DIR/${name}.log" || true
        fi
        printf '%s\t%s\t%s\t0\t0\t0\t1\t?\n' "$name" "$round" "$conc" >>"$OUT_DIR/runs.tsv"
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return
    fi
    blen=$(wc -c < /tmp/http_probe.body | tr -d ' ')
    load_out="$OUT_DIR/${name}_r${round}_c${conc}.wrk"
    set -- $(run_load "$port" "$conc" "$load_out")
    rps=$1; p50=$2; p99=$3; err=$4
    rss=$(rss_kb "$pid")
    printf '%s conc=%s rps=%s p50_ms=%s p99_ms=%s errors=%s rss_kb=%s body=%s\n' \
        "$name" "$conc" "$rps" "$p50" "$p99" "$err" "$rss" "$blen"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$round" "$conc" "$rps" "$p50" "$p99" "$err" "$rss" >>"$OUT_DIR/runs.tsv"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.15
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 0.2
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

echo "http bench duration=$DUR concs=$CONCS rounds=$ROUNDS"
echo "langs=$LANGS"
echo "loadgen=$(command -v wrk || echo "$LG_BIN")"
echo "order rotates each round"

r=1
while [ "$r" -le "$ROUNDS" ]; do
    echo "-- round $r --"
    for name in $(rotate_langs "$r"); do
        for conc in $CONCS; do
            run_server "$name" "$conc" "$r"
        done
    done
    r=$((r + 1))
done

echo "-- medians --"
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
{
    key = $1 " c=" $3
    n[key]++
    rps[key, n[key]] = $4
    p50[key, n[key]] = $5
    p99[key, n[key]] = $6
    err[key, n[key]] = $7
    rss[key, n[key]] = $8
}
END {
    for (k in n) {
        nw = n[k]
        split("", a1); split("", a2); split("", a3); split("", a4); split("", a5)
        for (i = 1; i <= nw; i++) {
            a1[i] = rps[k, i]; a2[i] = p50[k, i]; a3[i] = p99[k, i]
            a4[i] = err[k, i]; a5[i] = rss[k, i]
        }
        printf "%s rps=%s p50_ms=%s p99_ms=%s errors=%s rss_kb=%s n=%d\n", \
            k, med(a1, nw), med(a2, nw), med(a3, nw), med(a4, nw), med(a5, nw), nw
    }
}
' "$OUT_DIR/runs.tsv"
