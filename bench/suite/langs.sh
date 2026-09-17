# How every implementation is built and started. The single source of truth
# for flags (bench/SPEC.md, rule 2). Sourced by bench/suite/run.sh.
#
#   build_lang <lang>            build all four workloads into $BIN/<lang>/
#   cmd <workload> <lang>        print the command that runs one of them
#
# Workloads: http (light), compute (light), api (heavy), batch (heavy).
# The harness exports, before calling cmd:
#   WORKERS        cores allotted to the program under test
#   HTTP_PORT      light/http
#   PORT DATABASE_URL DB_POOL_TOTAL   heavy/api
#   CC_TASKS CC_WORK CC_ALLOC         light/compute
# and pins the process with taskset. batch takes the CSV path as argv[1].

LANGS_ALL="slang go rust c csharp java python bun node"

: "${ROOT:?ROOT must be the repository root}"
: "${BIN:?BIN must be the build output directory}"

JAVA_API_OPTS="${JAVA_API_OPTS:--XX:+UseParallelGC -Xmx2g}"
JAVA_BATCH_OPTS="${JAVA_BATCH_OPTS:--XX:+UseParallelGC -Xmx12g}"
JAVA_LIGHT_OPTS="${JAVA_LIGHT_OPTS:--XX:+UseParallelGC}"

build_lang() {
    lang=$1
    out="$BIN/$lang"
    mkdir -p "$out"
    case $lang in
    slang)
        # make only checks mtimes, not platform: a slangc built on a
        # different OS/arch (e.g. the same checkout used on macOS before
        # being mounted into this Linux host) looks up to date and make
        # silently keeps it, which then fails as "Exec format error" deep
        # into the build. Always rebuild it here; it's a few seconds.
        (cd "$ROOT" && rm -f slangc && make -s slangc) &&
        "$ROOT/slangc" "$ROOT/bench/http_opt/main.sl" -o "$out/http" &&
        "$ROOT/slangc" "$ROOT/stress_test/programs/concurrent_compute/main.sl" -o "$out/compute" &&
        "$ROOT/slangc" "$ROOT/bench/suite/api/slang/main.sl" -o "$out/api" &&
        "$ROOT/slangc" "$ROOT/bench/suite/batch/slang/main.sl" -o "$out/batch"
        ;;
    go)
        go build -trimpath -ldflags="-s -w" -o "$out/http" "$ROOT/bench/http/go_raw/main.go" &&
        go build -trimpath -ldflags="-s -w" -o "$out/compute" "$ROOT/bench/compute/main.go" &&
        (cd "$ROOT/bench/suite/api/go" && go build -trimpath -ldflags="-s -w" -o "$out/api" .) &&
        (cd "$ROOT/bench/suite/batch/go" && go build -trimpath -ldflags="-s -w" -o "$out/batch" .)
        ;;
    rust)
        cargo build --release --quiet --manifest-path "$ROOT/bench/http/rust_raw/Cargo.toml" --target-dir "$out/target-http" &&
        cp "$out/target-http/release/http_bench_raw" "$out/http" &&
        rustc --edition 2021 -C opt-level=3 -C target-cpu=native -C codegen-units=1 \
            -o "$out/compute" "$ROOT/bench/compute/main.rs" &&
        RUSTFLAGS="-C target-cpu=native" cargo build --release --quiet \
            --manifest-path "$ROOT/bench/suite/api/rust/Cargo.toml" --target-dir "$out/target-api" &&
        cp "$out/target-api/release/api" "$out/api" &&
        RUSTFLAGS="-C target-cpu=native" cargo build --release --quiet \
            --manifest-path "$ROOT/bench/suite/batch/rust/Cargo.toml" --target-dir "$out/target-batch" &&
        cp "$out/target-batch/release/batch" "$out/batch"
        ;;
    c)
        cc -O3 -march=native -flto -std=c11 -D_GNU_SOURCE -o "$out/http" "$ROOT/bench/http/main.c" -lpthread &&
        cc -O3 -march=native -flto -std=c11 -D_GNU_SOURCE -o "$out/compute" "$ROOT/bench/compute/main.c" -lpthread &&
        cc -O3 -march=native -flto $(pkg-config --cflags libpq) -o "$out/api" \
            "$ROOT/bench/suite/api/c/server.c" $(pkg-config --libs libpq) -lpthread &&
        cc -O3 -march=native -flto -o "$out/batch" "$ROOT/bench/suite/batch/c/batch.c" -lpthread
        ;;
    csharp)
        dotnet publish "$ROOT/bench/suite/light/http/csharp/HttpRaw.csproj" -c Release -o "$out/http" --nologo -v q &&
        dotnet publish "$ROOT/bench/compute/cs/Compute.csproj" -c Release -o "$out/compute" --nologo -v q \
            -p:TargetFramework=net10.0 -p:ServerGarbageCollection=true -p:TieredPGO=true &&
        dotnet publish "$ROOT/bench/suite/api/csharp/Api.csproj" -c Release -o "$out/api" --nologo -v q &&
        dotnet publish "$ROOT/bench/suite/batch/csharp/Batch.csproj" -c Release -o "$out/batch" --nologo -v q
        ;;
    java)
        mkdir -p "$out/http" "$out/compute" "$out/batch" &&
        javac -d "$out/http" "$ROOT/bench/suite/light/http/HttpRaw.java" &&
        javac -d "$out/compute" "$ROOT/bench/compute/Compute.java" &&
        (cd "$ROOT/bench/suite/api/java" && mvn -q -B package -DskipTests) &&
        cp "$ROOT/bench/suite/api/java/target/api.jar" "$out/api.jar" &&
        javac -d "$out/batch" "$ROOT/bench/suite/batch/java/Batch.java"
        ;;
    python)
        python3 -m venv "$out/venv" &&
        "$out/venv/bin/pip" install -q -r "$ROOT/bench/suite/api/python/requirements.txt"
        ;;
    bun)
        bun --version >/dev/null
        ;;
    node)
        (cd "$ROOT/bench/suite/api/node" && npm ci --silent)
        ;;
    *)
        echo "unknown language: $lang" >&2
        return 2
        ;;
    esac
}

cmd() {
    workload=$1
    lang=$2
    out="$BIN/$lang"
    case "$lang/$workload" in
    # WORKERS is the app-level concurrency knob main.sl reads for its own
    # acceptor/worker count (api's accept-loop count, batch's CSV worker
    # count); SLANG_WORKERS sizes the runtime's own green-thread scheduler
    # pool. Both must track the cores the harness allotted, or slang runs
    # with its hardcoded defaults (1 acceptor, 8 batch workers) no matter
    # what WORKERS the rest of this file computes.
    slang/http)    echo "env HTTP_ACCEPTORS=$WORKERS SLANG_WORKERS=$WORKERS $out/http" ;;
    slang/compute) echo "env SLANG_WORKERS=$WORKERS $out/compute" ;;
    slang/api)     echo "env WORKERS=$WORKERS SLANG_WORKERS=$WORKERS $out/api" ;;
    slang/batch)   echo "env WORKERS=$WORKERS SLANG_WORKERS=$WORKERS $out/batch" ;;
    go/*|rust/*|c/*) echo "$out/$workload" ;;
    csharp/http)    echo "env DOTNET_ROOT=/usr/local/dotnet $out/http/HttpRaw" ;;
    csharp/compute) echo "env DOTNET_ROOT=/usr/local/dotnet $out/compute/Compute" ;;
    csharp/api)     echo "env DOTNET_ROOT=/usr/local/dotnet $out/api/Api" ;;
    csharp/batch)   echo "env DOTNET_ROOT=/usr/local/dotnet $out/batch/Batch" ;;
    java/http)    echo "java $JAVA_LIGHT_OPTS -cp $out/http HttpRaw" ;;
    java/compute) echo "java $JAVA_LIGHT_OPTS -cp $out/compute Compute" ;;
    java/api)     echo "java $JAVA_API_OPTS -jar $out/api.jar" ;;
    java/batch)   echo "java $JAVA_BATCH_OPTS -cp $out/batch Batch" ;;
    python/http)    echo "$out/venv/bin/python $ROOT/bench/suite/light/http/python.py" ;;
    python/compute) echo "$out/venv/bin/python $ROOT/bench/suite/light/compute/compute.py" ;;
    python/api)     echo "$out/venv/bin/python $ROOT/bench/suite/api/python/server.py" ;;
    python/batch)   echo "$out/venv/bin/python $ROOT/bench/suite/batch/python/batch.py" ;;
    bun/http)    echo "bun $ROOT/bench/suite/light/http/bun.js" ;;
    bun/compute) echo "bun $ROOT/bench/suite/light/compute/compute.mjs" ;;
    bun/api)     echo "bun $ROOT/bench/suite/api/bun/server.js" ;;
    bun/batch)   echo "bun $ROOT/bench/suite/batch/js/batch.mjs" ;;
    node/http)    echo "node $ROOT/bench/suite/light/http/node.mjs" ;;
    node/compute) echo "node $ROOT/bench/suite/light/compute/compute.mjs" ;;
    node/api)     echo "node $ROOT/bench/suite/api/node/server.js" ;;
    node/batch)   echo "node --max-old-space-size=16384 $ROOT/bench/suite/batch/js/batch.mjs" ;;
    *) echo "no command for $lang/$workload" >&2; return 2 ;;
    esac
}
