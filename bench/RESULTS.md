# Phase E HTTP-only remasure (`fb39867`, io_wake off)

HTTP-only remasure on this Linux VM at `fb39867` (`revert(runtime): drop io_wake async-preempt skip`). Interned `b"..."`, arena freelist, and cheap interned-bytes for-in are still on the branch. The acceptor-hog `io_wake` skip is **not**. Compute was **not** rerun.

**slang does not win Phase E HTTP vs Go / C / Rust.** Dropping `io_wake` did **not** recover the PR #9 tail. Median RPS is still below PR #9 and in line with the bad PR #10 (`c4cc103`, io_wake on). p99 is worse than both prior slang rows (c=50 **127.86 ms** vs PR #9 **15.52** / PR #10 **84.4**). RSS is a few percent below PR #9 and matches PR #10 (~58 MB). That is still 3–33× Go / C / Rust.

Do not treat higher RPS than Go / Java / Zig / C# as a win. The file's own HTTP win conditions need p99 **and** RSS, and slang has neither vs Go / C / Rust.

Measured SHA: `fb398671c1e84c1290d40df48ec3dbbd5fb83a40` (`cursor/http-only-remasure-8157`). Branch: `async-preemption` + this RESULTS commit. Log/TSV: `/tmp/slang_phase_e_http`.

| commit | in this run? |
|---|---|
| `1c25b07` interned `b"..."` + `M_ARENA_MAX=2` | yes |
| `9c1763b` arena freelist | yes |
| `2f7c20e` cheap interned bytes for-in | yes |
| `c4cc103` skip async preempt after reactor I/O wake | **no** (reverted by `fb39867`) |

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-09-06 17:48 |
| uname | `Linux cursor 6.12.94+ #1 SMP PREEMPT_DYNAMIC Fri Sep 4 16:05:28 UTC 2026 x86_64` |
| OS | Ubuntu 24.04.4 LTS (noble) |
| CPU | Intel Xeon, 4 cores, 1 thread/core, 1 socket |
| nproc | 4 |
| RAM | 16398384 kB (~15.6 GiB); no swap |
| cc | Ubuntu clang 18.1.3 (1ubuntu1) |
| gcc | 13.3.0-6ubuntu2~24.04.1 |
| go | go1.22.2 linux/amd64 |
| rustc / cargo | 1.83.0 (90b35a623) / 1.83.0 (5ffbef321) |
| javac / java | 21.0.10 / OpenJDK 21.0.10+7-Ubuntu-124.04 |
| zig | 0.13.0 |
| dotnet | SDK 8.0.424, runtime 8.0.30 |
| wrk | debian/4.1.0-4build2 [epoll] |
| loadgen | wrk (Go `bench/http/loadgen.go` compiled but unused) |
| `git rev-parse HEAD` (measured tree) | `fb398671c1e84c1290d40df48ec3dbbd5fb83a40` |

No language was skipped. slang HTTP did not SIGSEGV. Zig compiled; c=200 still errors (harness limit). 8-worker floor unchanged.

## Commands / env

```
make slangc
HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http.sh
```

HTTP only. Did **not** run `./bench/run_phase_e.sh` or `./bench/run_compute.sh`.

Pinned HTTP ports: slang 18180, Go 18181, C 18182, Rust 18183, Java 18184, Zig 18185, C# 18186.

HTTP RSS: `/proc/$pid/status` `VmHWM` (kB). Order rotates (and reverses on even rounds) each round.

Compile notes:

- slangc time includes generated `cc -O3 -flto`
- C HTTP: `cc -O3 -flto -std=c11`
- Rust HTTP: `cargo build --release` after `cargo fetch` + `cargo clean`
- Java: `javac` then `java -cp`
- Zig: `zig build-exe -O ReleaseFast`
- C#: `dotnet restore` then timed `dotnet publish -c Release --no-restore`
- Go / Rust / Zig / C# compile seconds are higher than PR #9 on this boot (cold module / crate cache). Do not treat that as a slang compile win.

## HTTP

GET `/`, 200-byte `text/plain` body, `Connection: close`, no TLS. slang / C / Zig write HTTP/1.0 bytes. Go `net/http`, Rust axum, Java `HttpServer`, and C# `HttpListener` speak HTTP/1.1; body length was 200 on every probe.

`wrk -t4 -c{50,200} -d10s --latency` (threads = min(nproc, conc)). 3 rounds.

### Compile times (seconds)

| slang | go | cc -O3 -flto | rust axum release | javac | zig ReleaseFast | dotnet publish |
|---:|---:|---:|---:|---:|---:|---:|
| 0.42 | 2.57 | 0.08 | 11.05 | 0.43 | 6.94 | 1.77 |

### Per-round, c=50

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 72587.43 | 0.464 | 127.86 | 0 | 58320 | 200 |
| 1 | go | 67099.71 | 0.511 | 2.72 | 0 | 15376 | 200 |
| 1 | c | 97597.91 | 0.229 | 1.25 | 0 | 1784 | 200 |
| 1 | rust | 74587.05 | 0.519 | 1.11 | 0 | 4136 | 200 |
| 1 | java | 38045.58 | 0.86 | 7.19 | 0 | 372620 | 200 |
| 1 | zig | 36984.77 | 1.22 | 2.05 | 0 | 652 | 200 |
| 1 | csharp | 33318.19 | 0.77 | 56.71 | 0 | 204452 | 200 |
| 2 | slang | 72539.15 | 0.463 | 133.01 | 0 | 57920 | 200 |
| 2 | csharp | 34183.21 | 0.759 | 53.82 | 0 | 204660 | 200 |
| 2 | zig | 36015.28 | 1.25 | 2.11 | 0 | 720 | 200 |
| 2 | java | 37625.48 | 0.88 | 7.05 | 0 | 441396 | 200 |
| 2 | rust | 72968.61 | 0.526 | 1.14 | 0 | 4144 | 200 |
| 2 | c | 101928.26 | 0.216 | 1.18 | 0 | 1784 | 200 |
| 2 | go | 67726.92 | 0.505 | 2.60 | 0 | 15204 | 200 |
| 3 | c | 100188.68 | 0.221 | 1.19 | 0 | 1784 | 200 |
| 3 | rust | 74327.28 | 0.515 | 1.11 | 0 | 4092 | 200 |
| 3 | java | 36716.74 | 0.93 | 7.26 | 0 | 378636 | 200 |
| 3 | zig | 36010.53 | 1.25 | 2.08 | 0 | 756 | 200 |
| 3 | csharp | 34987.28 | 0.766 | 50.28 | 0 | 205156 | 200 |
| 3 | slang | 73056.89 | 0.462 | 126.22 | 0 | 58072 | 200 |
| 3 | go | 66587.80 | 0.514 | 2.66 | 0 | 14960 | 200 |

### Per-round, c=200

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 79843.73 | 1.81 | 103.11 | 0 | 58552 | 200 |
| 1 | go | 67330.82 | 2.34 | 7.22 | 0 | 18536 | 200 |
| 1 | c | 100245.74 | 0.93 | 3.94 | 0 | 1784 | 200 |
| 1 | rust | 75196.07 | 1.42 | 3.29 | 0 | 4908 | 200 |
| 1 | java | 41457.50 | 3.98 | 17.36 | 0 | 446936 | 200 |
| 1 | zig | 36170.72 | 3.49 | 699.48 | 5 | 864 | 200 |
| 1 | csharp | 36003.49 | 2.86 | 57.78 | 0 | 209512 | 200 |
| 2 | slang | 80003.97 | 1.82 | 100.78 | 0 | 58636 | 200 |
| 2 | csharp | 35623.81 | 2.95 | 61.16 | 0 | 204800 | 200 |
| 2 | zig | 37066.55 | 3.39 | 331.97 | 11 | 940 | 200 |
| 2 | java | 44711.66 | 3.77 | 13.90 | 0 | 446400 | 200 |
| 2 | rust | 73524.54 | 1.45 | 3.61 | 0 | 4788 | 200 |
| 2 | c | 100816.91 | 0.93 | 3.99 | 0 | 1792 | 200 |
| 2 | go | 68538.77 | 2.31 | 7.39 | 0 | 19340 | 200 |
| 3 | c | 100274.57 | 0.93 | 3.96 | 0 | 1788 | 200 |
| 3 | rust | 75340.67 | 1.39 | 3.31 | 0 | 4872 | 200 |
| 3 | java | 43041.41 | 3.90 | 15.85 | 0 | 370464 | 200 |
| 3 | zig | 36419.66 | 3.46 | 626.05 | 8 | 904 | 200 |
| 3 | csharp | 33918.77 | 2.99 | 65.07 | 0 | 205028 | 200 |
| 3 | slang | 79344.37 | 1.84 | 111.99 | 0 | 58840 | 200 |
| 3 | go | 68237.12 | 2.32 | 7.20 | 0 | 18052 | 200 |

### Medians (n=3)

c=50

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 100188.68 | 0.221 | 1.19 | 0 | 1784 |
| rust | 74327.28 | 0.519 | 1.11 | 0 | 4136 |
| slang | 72587.43 | 0.463 | 127.86 | 0 | 58072 |
| go | 67099.71 | 0.511 | 2.66 | 0 | 15204 |
| java | 37625.48 | 0.88 | 7.19 | 0 | 378636 |
| zig | 36015.28 | 1.25 | 2.08 | 0 | 720 |
| csharp | 34183.21 | 0.766 | 53.82 | 0 | 204660 |

c=200

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 100274.57 | 0.93 | 3.96 | 0 | 1788 |
| slang | 79843.73 | 1.82 | 103.11 | 0 | 58636 |
| rust | 75196.07 | 1.42 | 3.31 | 0 | 4872 |
| go | 68237.12 | 2.32 | 7.22 | 0 | 18536 |
| java | 43041.41 | 3.90 | 15.85 | 0 | 446400 |
| zig | 36419.66 | 3.46 | 626.05 | 8 | 904 |
| csharp | 35623.81 | 2.95 | 61.16 | 0 | 205028 |

Zig at c=200 is a raw `accept` + `Thread.spawn` per connection with no pool. It drops connections (median 8 wrk socket errors; rounds were 5 / 11 / 8) and the tail blows out (median p99 626 ms). That is a Zig harness limit, not a slang win.

C# RPS is lower than PR #9 / PR #10 on this pass (~34k vs ~44k at c=50). Peer tails for C / Go / Rust are in the same band as those remasures, so slang's 100–130 ms p99 is not "the box got slower."

### HTTP vs peers (median)

Need **higher RPS or lower p99, and lower RSS** to call a win vs Go. Need ~10% of C on RPS/p99. Need faster compile than Rust **and** p99/RSS no worse.

| vs | c=50 | c=200 | compile | result |
|---|---|---|---|---|
| C | RPS 28% lower (72587 / 100189); p99 107× worse (127.86 / 1.19); RSS 33× | RPS 20% lower; p99 26× worse; RSS 33× | slang 0.42s vs C 0.08s | **lose** |
| Go | RPS +8%; p50 better; p99 48× worse (127.86 / 2.66); RSS 3.8× | RPS +17%; p50 better; p99 14× worse; RSS 3.2× | slang 0.42s vs Go 2.57s (cold cache) | **lose** (RPS up, tail and RSS down) |
| Rust | RPS 2% lower (72587 / 74327); p99 115× worse; RSS 14× | RPS +6%; p99 31× worse; RSS 12× | slang 0.42s vs 11.05s | compile wins; **RPS/p99/RSS lose** at c=50 |
| Java | RPS 1.9×; p99 18× worse; RSS 6.5× better | RPS 1.9×; p99 6.5× worse; RSS 7.6× better | similar (0.42 vs 0.43) | beats Java on RPS and RSS; **loses p99** |
| Zig | RPS 2.0×; p99 62× worse; RSS 81× worse | RPS 2.2×; Zig errors + p99 626 ms | slang 0.42s vs 6.94s | higher RPS, much worse RSS; Zig c=200 is broken |
| C# | RPS 2.1×; p99 worse (127.86 vs 53.82); RSS 3.5× better | RPS 2.2×; p99 worse (103.11 vs 61.16); RSS 3.5× better | slang 0.42s vs 1.77s | beats C# on RPS and RSS; **loses p99** |

### slang vs PR #9 (`a64f079`) and PR #10 (`c4cc103`, io_wake on)

| metric | PR #9 | PR #10 (io_wake on) | this run (io_wake off) | vs #9 | vs #10 |
|---|---:|---:|---:|---|---|
| c=50 rps | 80692.13 | 73800.51 | 72587.43 | −10% | −1.6% |
| c=50 p99_ms | 15.52 | 84.4 | 127.86 | 8.2× worse | 1.5× worse |
| c=50 rss_kb | 60560 | 58028 | 58072 | −4% | ~same |
| c=200 rps | 85751.48 | 79228.57 | 79843.73 | −6.9% | +0.8% |
| c=200 p99_ms | 16.59 | 70.47 | 103.11 | 6.2× worse | 1.5× worse |
| c=200 rss_kb | 61872 | 58744 | 58636 | −5% | ~same |

Peer HTTP medians this pass (C c=50 100189, Rust 74327, Go 67100) are in the same band as PR #9 / PR #10. slang's p99 change is not explained by the box.

## Verdict (this remasure)

| comparison | result |
|---|---|
| HTTP vs C (~10% RPS/p99) | **lose** — 20–28% lower RPS; p99 26–107× worse; RSS ~33×. |
| HTTP vs Go (RPS or p99, **and** RSS) | **lose** — RPS is higher; p99 and RSS are worse. |
| HTTP vs Rust (faster compile; p99/RSS no worse) | **lose** — compile 0.42s vs 11.05s; c=50 RPS now loses; p99 and RSS lose. |
| HTTP vs Java / C# | higher RPS and lower RSS than both; **loses p99 to both**. |
| HTTP vs Zig | higher RPS; Zig RSS is tiny; Zig c=200 errors. Not a framework-fair fight. |
| vs PR #9 slang | RPS **down**, p99 **much worse**, RSS slightly better. Not a win. |
| vs PR #10 slang | RPS ~same, RSS ~same, p99 **worse**. Reverting `io_wake` did not restore the PR #9 tail. |
| interned bytes / freelist / cheap for-in | **did not** move p99/RSS onto the Phase E win side of Go / C / Rust. |

Narrow facts, not overall wins:

- No slang HTTP SIGSEGV. No language skipped.
- slang HTTP median RPS still beats Go, Java, Zig, and C# at both concurrencies. It loses c=50 RPS to Rust and C.
- slang HTTP compiles much faster than tokio/axum (0.42s vs 11.05s).
- C still owns HTTP RPS, p99, and RSS. Rust owns HTTP tail latency among the managed/async servers, and also c=50 RPS vs slang.
- slang HTTP RSS (~58 MB) is still the standout loss vs C / Rust / Go. The request-path cuts did not fix it.
- slang HTTP p99 is the standout regression vs PR #9, and it is **worse** with `io_wake` off than the PR #10 run that had `io_wake` on. All three c=50 rounds were bad (127.86 / 133.01 / 126.22). Do not paper over that.

No LLVM. No slang syntax changes. Bench programs, wrk flags, body size, conc, duration, and the 8-worker floor are unchanged. This run excludes compute.

---

# Earlier remasure: PR #10 (`c4cc103`, io_wake on)

Draft PR #10 measured the same request-path cuts **plus** `c4cc103` (skip async preempt after reactor I/O wake). Full compute + HTTP tables lived on `cursor/phase-e-remasure-12bf`. slang HTTP medians from that run:

| conc | rps | p99_ms | rss_kb |
|---|---:|---:|---:|
| 50 | 73800.51 | 84.4 | 58028 |
| 200 | 79228.57 | 70.47 | 58744 |

That remasure already lost HTTP p99/RSS to Go / C / Rust. Compute wall improved vs PR #9 (60 → 46 ms) and still lost to C / Rust. Included here so the `fb39867` HTTP row above can be read against both histories.

---

# Earlier remasure: PR #9 (`a64f079`, Phase E rerun)

Measured on this Linux VM after the `-O3` SIGSEGV fix, cheap back-edges, flat arithmetic, nested-while skip, 256KB pthread stacks, 8KB green-stack freelist, and `net.recv` scratch-off-GC.

**slang does not win the original Phase E goals vs Go / C / Rust.** It is faster than Go on compute wall and HTTP RPS, and faster than C/Rust on HTTP compile, but it loses compute wall to C and Rust, loses HTTP RPS to C, and loses HTTP p99 and RSS to Go, C, and Rust.

Java / Zig / C# are first-class peers in this run. slang beats those three on compute wall and HTTP RPS. That does not make an overall win.

Harness SHA for this run: `2541d08cb619c8517f8a7010892f143e7bc83e9e` (`cursor/phase-e-rerun-0b3a`). Base: `async-preemption` `a64f079`.

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-09-06 16:23 |
| uname | `Linux cursor 6.12.94+ #1 SMP PREEMPT_DYNAMIC Fri Sep 4 16:05:28 UTC 2026 x86_64` |
| OS | Ubuntu 24.04.4 LTS (noble) |
| CPU | Intel Xeon, 4 cores, 1 thread/core, 1 socket |
| nproc | 4 |
| RAM | 16398384 kB (~15.6 GiB); no swap |
| cc | Ubuntu clang 18.1.3 (1ubuntu1) |
| gcc | 13.3.0-6ubuntu2~24.04.1 |
| go | go1.22.2 linux/amd64 |
| rustc / cargo | 1.83.0 (90b35a623) / 1.83.0 (5ffbef321) |
| javac / java | 21.0.10 / OpenJDK 21.0.10+7-Ubuntu-124.04 |
| zig | 0.13.0 |
| dotnet | SDK 8.0.424, runtime 8.0.30 |
| wrk | debian/4.1.0-4build2 [epoll] |
| loadgen | wrk (Go `bench/http/loadgen.go` compiled but unused) |

No language was skipped.

## Commands / env

```
make slangc
CC_TASKS=200 CC_WORK=8000 CC_ALLOC=50 CC_ROUNDS=3 ./bench/run_compute.sh
HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http.sh
```

Or `./bench/run_phase_e.sh` (same defaults).

Pinned HTTP ports: slang 18180, Go 18181, C 18182, Rust 18183, Java 18184, Zig 18185, C# 18186.

Compute RSS: GNU `/usr/bin/time -f '%M'` (kB). HTTP RSS: `/proc/$pid/status` `VmHWM` (kB). Order rotates (and reverses on even rounds) each round.

Compile notes:

- slangc time includes generated `cc -O3 -flto`
- C compute: `cc -O3 -std=c11 -D_GNU_SOURCE` (flag only; alloc half unchanged)
- C HTTP: `cc -O3 -flto -std=c11`
- Rust compute: `rustc -C opt-level=3`
- Rust HTTP: `cargo build --release` after `cargo fetch` + `cargo clean`
- Java: `javac` then `java -cp`
- Zig: `zig build-exe -O ReleaseFast`
- C#: `dotnet restore` then timed `dotnet publish -c Release --no-restore`

## Compute

Workload: 200 tasks, primes in `[0, 8000)` with trial division and **no early break**, plus list + string-keyed map of 50 entries (C keeps the existing malloc / `strlen` half; its `total_alloc_sum` is not comparable).

Every language reported `total_primes=201400`. Map-comparable `total_alloc_sum=490000` (slang, Go, Rust, Java, Zig, C#). C reported `508000`.

### Compile times (seconds)

| slang GC | slang arena | go | cc -O3 | rustc -O3 | javac | zig ReleaseFast | dotnet publish |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.44 | 0.38 | 0.02 | 0.05 | 0.21 | 0.34 | 5.13 | 0.68 |

### Per-round

Round 1 order: slang, go, c, rust, java, zig, csharp

| lang | wall_ms | rss_kb | tasks_per_sec | total_primes | total_alloc_sum |
|---|---:|---:|---:|---:|---:|
| slang | 45 | 6116 | 4444 | 201400 | 490000 |
| go | 67 | 2680 | 2985 | 201400 | 490000 |
| c | 42 | 2764 | 4761 | 201400 | 508000 |
| rust | 48 | 3916 | 4166 | 201400 | 490000 |
| java | 133 | 48580 | 1503 | 201400 | 490000 |
| zig | 73 | 2468 | 2739 | 201400 | 490000 |
| csharp | 96 | 28572 | 2083 | 201400 | 490000 |

Round 2 order: slang, csharp, zig, java, rust, c, go

| lang | wall_ms | rss_kb | tasks_per_sec | total_primes | total_alloc_sum |
|---|---:|---:|---:|---:|---:|
| slang | 60 | 6244 | 3333 | 201400 | 490000 |
| csharp | 83 | 28816 | 2409 | 201400 | 490000 |
| zig | 70 | 3108 | 2857 | 201400 | 490000 |
| java | 131 | 48668 | 1526 | 201400 | 490000 |
| rust | 51 | 4020 | 3921 | 201400 | 490000 |
| c | 51 | 3020 | 3921 | 201400 | 508000 |
| go | 90 | 2700 | 2222 | 201400 | 490000 |

Round 3 order: c, rust, java, zig, csharp, slang, go

| lang | wall_ms | rss_kb | tasks_per_sec | total_primes | total_alloc_sum |
|---|---:|---:|---:|---:|---:|
| c | 42 | 3020 | 4761 | 201400 | 508000 |
| rust | 46 | 3748 | 4347 | 201400 | 490000 |
| java | 123 | 48424 | 1626 | 201400 | 490000 |
| zig | 69 | 3236 | 2898 | 201400 | 490000 |
| csharp | 88 | 28768 | 2272 | 201400 | 490000 |
| slang | 60 | 6244 | 3333 | 201400 | 490000 |
| go | 91 | 2680 | 2197 | 201400 | 490000 |

Extra (not vs maps): slang arena `wall_ms=57 rss_kb=3544 tasks_per_sec=3508 total_primes=201400 total_alloc_sum=490000` (n=1).

### Medians (n=3)

| lang | wall_ms | rss_kb | tasks_per_sec |
|---|---:|---:|---:|
| c | 42 | 3020 | 4761 |
| rust | 48 | 3916 | 4166 |
| slang | 60 | 6244 | 3333 |
| zig | 70 | 3108 | 2857 |
| csharp | 88 | 28768 | 2272 |
| go | 90 | 2680 | 2222 |
| java | 131 | 48580 | 1526 |

No compute crashes. slang GC did not SIGSEGV.

### Compute vs peers (median wall)

| vs | slang / other | result |
|---|---|---|
| C | 60 / 42 = 1.43× | **lose** (also lose RSS: 6244 vs 3020) |
| Rust | 60 / 48 = 1.25× | **lose** (also lose RSS: 6244 vs 3916) |
| Go | 60 / 90 = 0.67× | faster wall; **lose RSS** (6244 vs 2680, 2.3×) |
| Zig | 60 / 70 = 0.86× | faster wall; **lose RSS** (6244 vs 3108) |
| C# | 60 / 88 = 0.68× | faster wall and RSS (6244 vs 28768) |
| Java | 60 / 131 = 0.46× | faster wall and RSS (6244 vs 48580) |

C's alloc path is weaker (no string map). Do not treat C's wall as a map-vs-map win for C, but C still wins the prime loop + pthread spawn on this box.

## HTTP

GET `/`, 200-byte `text/plain` body, `Connection: close`, no TLS. slang / C / Zig write HTTP/1.0 bytes. Go `net/http`, Rust axum, Java `HttpServer`, and C# `HttpListener` speak HTTP/1.1; body length was 200 on every probe.

`wrk -t4 -c{50,200} -d10s --latency` (threads = min(nproc, conc)). 3 rounds.

### Compile times (seconds)

| slang | go | cc -O3 -flto | rust axum release | javac | zig ReleaseFast | dotnet publish |
|---:|---:|---:|---:|---:|---:|---:|
| 0.40 | 0.20 | 0.07 | 9.69 | 0.31 | 4.48 | 0.57 |

### Per-round, c=50

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 80692.13 | 0.406 | 15.51 | 0 | 60560 | 200 |
| 1 | go | 67870.96 | 0.500 | 2.65 | 0 | 15100 | 200 |
| 1 | c | 105132.75 | 0.223 | 1.35 | 0 | 1780 | 200 |
| 1 | rust | 77673.10 | 0.498 | 1.10 | 0 | 4184 | 200 |
| 1 | java | 43097.92 | 0.747 | 6.81 | 0 | 369868 | 200 |
| 1 | zig | 37197.86 | 1.220 | 1.91 | 0 | 652 | 200 |
| 1 | csharp | 45086.90 | 0.642 | 30.28 | 0 | 204792 | 200 |
| 2 | slang | 81439.74 | 0.403 | 15.52 | 0 | 56360 | 200 |
| 2 | csharp | 44467.40 | 0.657 | 30.33 | 0 | 208988 | 200 |
| 2 | zig | 36611.91 | 1.240 | 1.88 | 0 | 680 | 200 |
| 2 | java | 38832.67 | 0.801 | 7.41 | 0 | 454480 | 200 |
| 2 | rust | 76639.71 | 0.501 | 1.09 | 0 | 4120 | 200 |
| 2 | c | 105930.10 | 0.212 | 1.11 | 0 | 1784 | 200 |
| 2 | go | 69997.60 | 0.490 | 2.71 | 0 | 14676 | 200 |
| 3 | c | 102891.11 | 0.220 | 1.15 | 0 | 1776 | 200 |
| 3 | rust | 76119.56 | 0.507 | 1.08 | 0 | 4168 | 200 |
| 3 | java | 36071.00 | 0.846 | 7.86 | 0 | 376256 | 200 |
| 3 | zig | 36863.68 | 1.230 | 1.91 | 0 | 788 | 200 |
| 3 | csharp | 43682.66 | 0.655 | 32.06 | 0 | 208884 | 200 |
| 3 | slang | 79397.90 | 0.417 | 16.22 | 0 | 60564 | 200 |
| 3 | go | 69216.10 | 0.489 | 3.02 | 0 | 14836 | 200 |

### Per-round, c=200

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 84552.09 | 1.62 | 16.59 | 0 | 61936 | 200 |
| 1 | go | 69066.87 | 2.29 | 7.33 | 0 | 17896 | 200 |
| 1 | c | 103577.75 | 0.90 | 3.88 | 0 | 1776 | 200 |
| 1 | rust | 76892.33 | 1.38 | 3.46 | 0 | 4828 | 200 |
| 1 | java | 39832.76 | 3.87 | 18.55 | 0 | 369420 | 200 |
| 1 | zig | 37108.01 | 3.40 | 184.07 | 16 | 796 | 200 |
| 1 | csharp | 47690.97 | 2.45 | 34.04 | 0 | 209020 | 200 |
| 2 | slang | 87089.26 | 1.56 | 16.45 | 0 | 61368 | 200 |
| 2 | csharp | 47486.00 | 2.48 | 34.00 | 0 | 205024 | 200 |
| 2 | zig | 36937.83 | 3.42 | 569.52 | 15 | 748 | 200 |
| 2 | java | 39954.56 | 3.79 | 19.80 | 0 | 377012 | 200 |
| 2 | rust | 77161.86 | 1.40 | 3.19 | 0 | 4784 | 200 |
| 2 | c | 104242.75 | 0.90 | 3.91 | 0 | 1788 | 200 |
| 2 | go | 71787.33 | 2.21 | 7.06 | 0 | 19608 | 200 |
| 3 | c | 100271.34 | 0.93 | 3.99 | 0 | 1784 | 200 |
| 3 | rust | 75517.52 | 1.39 | 3.27 | 0 | 4776 | 200 |
| 3 | java | 41933.29 | 3.83 | 17.11 | 0 | 454464 | 200 |
| 3 | zig | 37557.28 | 3.37 | 458.45 | 4 | 920 | 200 |
| 3 | csharp | 46184.71 | 2.54 | 35.51 | 0 | 208824 | 200 |
| 3 | slang | 85751.48 | 1.61 | 16.70 | 0 | 61872 | 200 |
| 3 | go | 69340.25 | 2.31 | 7.39 | 0 | 17776 | 200 |

### Medians (n=3)

c=50

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 105132.75 | 0.220 | 1.15 | 0 | 1780 |
| slang | 80692.13 | 0.406 | 15.52 | 0 | 60560 |
| rust | 76639.71 | 0.501 | 1.09 | 0 | 4168 |
| go | 69216.10 | 0.490 | 2.71 | 0 | 14836 |
| csharp | 44467.40 | 0.655 | 30.33 | 0 | 208884 |
| java | 38832.67 | 0.801 | 7.41 | 0 | 376256 |
| zig | 36863.68 | 1.230 | 1.91 | 0 | 680 |

c=200

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 103577.75 | 0.90 | 3.91 | 0 | 1784 |
| slang | 85751.48 | 1.61 | 16.59 | 0 | 61872 |
| rust | 76892.33 | 1.39 | 3.27 | 0 | 4784 |
| go | 69340.25 | 2.29 | 7.33 | 0 | 17896 |
| csharp | 47486.00 | 2.48 | 34.04 | 0 | 208824 |
| java | 39954.56 | 3.83 | 18.55 | 0 | 377012 |
| zig | 37108.01 | 3.40 | 458.45 | 15 | 796 |

Zig at c=200 is a raw `accept` + `Thread.spawn` per connection with no pool. It drops connections (median 15 wrk socket errors) and the tail blows out. That is a Zig harness limit, not a slang win to lean on.

### HTTP vs peers (median)

Need **higher RPS or lower p99, and lower RSS** to call a win vs Go. Need ~10% of C on RPS/p99. Need faster compile than Rust **and** p99/RSS no worse.

| vs | c=50 | c=200 | compile | result |
|---|---|---|---|---|
| C | RPS 23% lower (80692 / 105133); p99 13.5× worse (15.52 / 1.15); RSS 34× | RPS 17% lower; p99 4.2× worse; RSS 35× | slang 0.40s vs C 0.07s | **lose** |
| Go | RPS +17%; p50 better; p99 5.7× worse; RSS 4.1× | RPS +24%; p50 better; p99 2.3× worse; RSS 3.5× | slang 0.40s vs Go 0.20s | **lose** (RPS up, tail and RSS down) |
| Rust | RPS +5%; p99 14× worse; RSS 14.5× | RPS +12%; p99 5.1× worse; RSS 13× | slang 0.40s vs 9.69s | compile wins; **p99 and RSS lose** |
| Java | RPS 2.1×; p99 2.1× worse; RSS 6.2× better | RPS 2.1×; p99 slightly better; RSS 6.1× better | similar (0.40 vs 0.31) | beats Java on RPS and RSS; loses p99 at c=50 |
| Zig | RPS 2.2×; p99 8.1× worse; RSS 89× worse | RPS 2.3×; Zig errors + p99 458ms | slang 0.40s vs 4.48s | higher RPS, much worse RSS; Zig c=200 is broken |
| C# | RPS 1.8×; p99 better (15.52 vs 30.33); RSS 3.4× better | RPS 1.8×; p99 better; RSS 3.4× better | similar (0.40 vs 0.57) | beats C# on RPS, p99, RSS |

## Verdict

| comparison | result |
|---|---|
| Compute vs C | **lose** — 1.43× wall, higher RSS. C alloc is not a map, but C still finishes first. |
| Compute vs Rust | **lose** — 1.25× wall, higher RSS. Same algorithm (threads + `HashMap<String,_>`). |
| Compute vs Go | faster wall (0.67×); **lose RSS** (2.3×). Not a clean win. |
| Compute vs Java / Zig / C# | faster wall than all three. RSS beats Java and C#, loses to Zig. |
| HTTP vs C (~10% RPS/p99) | **lose** — 17–23% lower RPS; p99 4–14× worse; RSS ~34×. |
| HTTP vs Go (RPS or p99, **and** RSS) | **lose** — RPS is higher; p99 and RSS are worse. |
| HTTP vs Rust (faster compile; p99/RSS no worse) | **lose** — compile 0.40s vs 9.69s; p99 and RSS lose. |
| HTTP vs Java / C# | higher RPS and lower RSS than both; p99 beats C#, loses to Java at c=50. |
| HTTP vs Zig | higher RPS; Zig RSS is tiny; Zig c=200 errors. Not a framework-fair fight. |

Narrow facts, not overall wins:

- slang compute no longer SIGSEGVs at `-O3 -flto` on this workload.
- slang HTTP median RPS beats Go, Rust, Java, Zig, and C# at both concurrencies.
- slang HTTP compiles much faster than tokio/axum (0.40s vs 9.69s).
- C still owns HTTP RPS, p99, and RSS. Rust owns HTTP tail latency among the managed/async servers.
- slang HTTP RSS (~60 MB) is the standout loss vs C / Rust / Go.

No LLVM. No slang syntax changes. `count_primes_range` in `stress_test/programs/concurrent_compute/main.sl` is unchanged.
