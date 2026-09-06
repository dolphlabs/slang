# Phase E results (request-path remasure)

Measured on this Linux VM after interned `b"..."` + glibc `M_ARENA_MAX=2`, arena freelist, cheap interned-bytes for-in, and skip-async-preempt after reactor I/O wake. Previous published tables: PR #9 (`a64f079` / harness `2541d08`).

**slang does not win the original Phase E goals vs Go / C / Rust.** Compute wall improved vs the last remasure (46 ms vs 60 ms) and is still faster than Go / Java / Zig / C#, but it still loses compute wall and RSS to C and Rust. HTTP got worse, not better: median RPS dropped, p99 blew out (~15 ms → ~70–84 ms), and slang now loses c=50 RPS to Rust as well as C. RSS is slightly lower than last time and still far above Go / C / Rust.

This remasure includes these unmeasured-until-now request-path commits on `async-preemption`:

| commit | change |
|---|---|
| `1c25b07` | interned `b"..."` + glibc `M_ARENA_MAX=2` |
| `9c1763b` | arena freelist |
| `2f7c20e` | cheap interned bytes for-in |
| `c4cc103` | skip async preempt after reactor I/O wake |

Harness / measured SHA: `c4cc103e5272e3eb838049550a504cde6a716f1a` (`cursor/phase-e-remasure-12bf`). Branch base: `async-preemption` `c4cc103`.

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-09-06 17:28 |
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

No language was skipped. slangc and both slang bench binaries ran without SIGSEGV.

## Commands / env

```
make slangc
CC_TASKS=200 CC_WORK=8000 CC_ALLOC=50 CC_ROUNDS=3 ./bench/run_compute.sh
HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http.sh
```

Or `./bench/run_phase_e.sh` (same defaults). Log: `/tmp/slang_phase_e/phase_e.log`.

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
- Go / Rust compile seconds are higher than PR #9 on this boot (cold module / crate cache). Do not treat that as a slang compile win.

## Compute

Workload: 200 tasks, primes in `[0, 8000)` with trial division and **no early break**, plus list + string-keyed map of 50 entries (C keeps the existing malloc / `strlen` half; its `total_alloc_sum` is not comparable).

Every language reported `total_primes=201400`. Map-comparable `total_alloc_sum=490000` (slang, Go, Rust, Java, Zig, C#). C reported `508000`.

### Compile times (seconds)

| slang GC | slang arena | go | cc -O3 | rustc -O3 | javac | zig ReleaseFast | dotnet publish |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.46 | 0.41 | 2.55 | 0.07 | 1.13 | 0.48 | 7.31 | 1.79 |

### Per-round

Round 1 order: slang, go, c, rust, java, zig, csharp

| lang | wall_ms | rss_kb | tasks_per_sec | total_primes | total_alloc_sum |
|---|---:|---:|---:|---:|---:|
| slang | 47 | 6116 | 4255 | 201400 | 490000 |
| go | 68 | 2572 | 2941 | 201400 | 490000 |
| c | 40 | 3148 | 5000 | 201400 | 508000 |
| rust | 40 | 3388 | 5000 | 201400 | 490000 |
| java | 104 | 48860 | 1923 | 201400 | 490000 |
| zig | 73 | 2468 | 2739 | 201400 | 490000 |
| csharp | 75 | 28700 | 2666 | 201400 | 490000 |

Round 2 order: slang, csharp, zig, java, rust, c, go

| lang | wall_ms | rss_kb | tasks_per_sec | total_primes | total_alloc_sum |
|---|---:|---:|---:|---:|---:|
| slang | 46 | 6116 | 4347 | 201400 | 490000 |
| csharp | 67 | 28328 | 2985 | 201400 | 490000 |
| zig | 65 | 2084 | 3076 | 201400 | 490000 |
| java | 96 | 49040 | 2083 | 201400 | 490000 |
| rust | 41 | 3864 | 4878 | 201400 | 490000 |
| c | 39 | 3148 | 5128 | 201400 | 508000 |
| go | 69 | 2572 | 2898 | 201400 | 490000 |

Round 3 order: c, rust, java, zig, csharp, slang, go

| lang | wall_ms | rss_kb | tasks_per_sec | total_primes | total_alloc_sum |
|---|---:|---:|---:|---:|---:|
| c | 39 | 3148 | 5128 | 201400 | 508000 |
| rust | 40 | 3900 | 5000 | 201400 | 490000 |
| java | 105 | 48228 | 1904 | 201400 | 490000 |
| zig | 63 | 2336 | 3174 | 201400 | 490000 |
| csharp | 67 | 28636 | 2985 | 201400 | 490000 |
| slang | 46 | 6116 | 4347 | 201400 | 490000 |
| go | 68 | 2572 | 2941 | 201400 | 490000 |

Extra (not vs maps): slang arena `wall_ms=44 rss_kb=3548 tasks_per_sec=4545 total_primes=201400 total_alloc_sum=490000` (n=1).

### Medians (n=3)

| lang | wall_ms | rss_kb | tasks_per_sec |
|---|---:|---:|---:|
| c | 39 | 3148 | 5128 |
| rust | 40 | 3864 | 5000 |
| slang | 46 | 6116 | 4347 |
| zig | 65 | 2336 | 3076 |
| csharp | 67 | 28636 | 2985 |
| go | 68 | 2572 | 2941 |
| java | 104 | 48860 | 1923 |

No compute crashes. slang GC did not SIGSEGV.

### Compute vs peers (median wall)

| vs | slang / other | result |
|---|---|---|
| C | 46 / 39 = 1.18× | **lose** (also lose RSS: 6116 vs 3148) |
| Rust | 46 / 40 = 1.15× | **lose** (also lose RSS: 6116 vs 3864) |
| Go | 46 / 68 = 0.68× | faster wall; **lose RSS** (6116 vs 2572, 2.4×) |
| Zig | 46 / 65 = 0.71× | faster wall; **lose RSS** (6116 vs 2336) |
| C# | 46 / 67 = 0.69× | faster wall and RSS (6116 vs 28636) |
| Java | 46 / 104 = 0.44× | faster wall and RSS (6116 vs 48860) |

C's alloc path is weaker (no string map). Do not treat C's wall as a map-vs-map win for C, but C still wins the prime loop + pthread spawn on this box.

### Compute vs previous remasure (PR #9)

| lang | prev wall_ms | new wall_ms | prev rss_kb | new rss_kb |
|---|---:|---:|---:|---:|
| slang | 60 | 46 | 6244 | 6116 |
| c | 42 | 39 | 3020 | 3148 |
| rust | 48 | 40 | 3916 | 3864 |
| go | 90 | 68 | 2680 | 2572 |
| zig | 70 | 65 | 3108 | 2336 |
| csharp | 88 | 67 | 28768 | 28636 |
| java | 131 | 104 | 48580 | 48860 |

slang compute wall 60 → 46 ms (−23%); RSS 6244 → 6116 (−2%). Peers also ran faster on this pass, so the gap to C/Rust narrowed (1.43×/1.25× → 1.18×/1.15×) but did not close.

## HTTP

GET `/`, 200-byte `text/plain` body, `Connection: close`, no TLS. slang / C / Zig write HTTP/1.0 bytes. Go `net/http`, Rust axum, Java `HttpServer`, and C# `HttpListener` speak HTTP/1.1; body length was 200 on every probe.

`wrk -t4 -c{50,200} -d10s --latency` (threads = min(nproc, conc)). 3 rounds.

### Compile times (seconds)

| slang | go | cc -O3 -flto | rust axum release | javac | zig ReleaseFast | dotnet publish |
|---:|---:|---:|---:|---:|---:|---:|
| 0.41 | 3.74 | 0.08 | 10.35 | 0.40 | 4.77 | 0.70 |

### Per-round, c=50

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 72801.09 | 0.476 | 84.4 | 0 | 57940 | 200 |
| 1 | go | 66290.32 | 0.505 | 3.77 | 0 | 17412 | 200 |
| 1 | c | 103894.85 | 0.199 | 1.36 | 0 | 1784 | 200 |
| 1 | rust | 77973.11 | 0.486 | 1.83 | 0 | 4108 | 200 |
| 1 | java | 43632.72 | 0.725 | 6.98 | 0 | 366116 | 200 |
| 1 | zig | 36595.49 | 1.240 | 2.02 | 0 | 692 | 200 |
| 1 | csharp | 43638.57 | 0.667 | 32.23 | 0 | 204860 | 200 |
| 2 | slang | 78742.40 | 0.434 | 66.97 | 0 | 58224 | 200 |
| 2 | csharp | 44531.22 | 0.664 | 30.79 | 0 | 204548 | 200 |
| 2 | zig | 37470.69 | 1.210 | 2.04 | 0 | 708 | 200 |
| 2 | java | 44293.43 | 0.752 | 5.74 | 0 | 376504 | 200 |
| 2 | rust | 74255.24 | 0.519 | 1.16 | 0 | 4160 | 200 |
| 2 | c | 98543.25 | 0.226 | 1.50 | 0 | 1784 | 200 |
| 2 | go | 68940.14 | 0.501 | 3.08 | 0 | 14852 | 200 |
| 3 | c | 100236.91 | 0.219 | 1.31 | 0 | 1788 | 200 |
| 3 | rust | 77804.94 | 0.498 | 1.07 | 0 | 4136 | 200 |
| 3 | java | 35651.01 | 0.920 | 7.20 | 0 | 377000 | 200 |
| 3 | zig | 36001.13 | 1.250 | 2.82 | 0 | 808 | 200 |
| 3 | csharp | 34919.05 | 0.775 | 51.43 | 0 | 209340 | 200 |
| 3 | slang | 73800.51 | 0.451 | 106.51 | 0 | 58028 | 200 |
| 3 | go | 67787.51 | 0.502 | 3.09 | 0 | 15052 | 200 |

### Per-round, c=200

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 79228.57 | 1.88 | 70.47 | 0 | 58832 | 200 |
| 1 | go | 67671.80 | 2.38 | 8.50 | 0 | 18960 | 200 |
| 1 | c | 100729.20 | 0.93 | 3.94 | 0 | 1784 | 200 |
| 1 | rust | 74910.70 | 1.40 | 4.22 | 0 | 4812 | 200 |
| 1 | java | 42134.44 | 3.76 | 17.80 | 0 | 370936 | 200 |
| 1 | zig | 36885.76 | 3.41 | 348.61 | 10 | 848 | 200 |
| 1 | csharp | 42908.65 | 2.68 | 47.12 | 0 | 205772 | 200 |
| 2 | slang | 84745.28 | 1.76 | 57.74 | 0 | 58652 | 200 |
| 2 | csharp | 46341.40 | 2.50 | 35.92 | 0 | 208856 | 200 |
| 2 | zig | 35266.97 | 3.56 | 237.13 | 11 | 1072 | 200 |
| 2 | java | 43950.23 | 3.95 | 13.40 | 0 | 452304 | 200 |
| 2 | rust | 75629.83 | 1.40 | 3.48 | 0 | 4872 | 200 |
| 2 | c | 102417.38 | 0.92 | 3.99 | 0 | 1784 | 200 |
| 2 | go | 64517.31 | 2.45 | 7.72 | 0 | 19156 | 200 |
| 3 | c | 100623.58 | 0.93 | 3.96 | 0 | 1784 | 200 |
| 3 | rust | 75328.13 | 1.40 | 3.39 | 0 | 4800 | 200 |
| 3 | java | 42913.59 | 3.81 | 16.62 | 0 | 372208 | 200 |
| 3 | zig | 36891.86 | 3.39 | 349.32 | 0 | 1032 | 200 |
| 3 | csharp | 38899.33 | 2.84 | 51.73 | 0 | 209200 | 200 |
| 3 | slang | 78405.95 | 1.83 | 89.19 | 0 | 58744 | 200 |
| 3 | go | 65724.21 | 2.39 | 8.55 | 0 | 18436 | 200 |

### Medians (n=3)

c=50

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 100236.91 | 0.219 | 1.36 | 0 | 1784 |
| rust | 77804.94 | 0.498 | 1.16 | 0 | 4136 |
| slang | 73800.51 | 0.451 | 84.4 | 0 | 58028 |
| go | 67787.51 | 0.502 | 3.09 | 0 | 15052 |
| csharp | 43638.57 | 0.667 | 32.23 | 0 | 204860 |
| java | 43632.72 | 0.752 | 6.98 | 0 | 376504 |
| zig | 36595.49 | 1.240 | 2.04 | 0 | 708 |

c=200

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 100729.20 | 0.93 | 3.96 | 0 | 1784 |
| slang | 79228.57 | 1.83 | 70.47 | 0 | 58744 |
| rust | 75328.13 | 1.40 | 3.48 | 0 | 4812 |
| go | 65724.21 | 2.39 | 8.50 | 0 | 18960 |
| java | 42913.59 | 3.81 | 16.62 | 0 | 372208 |
| csharp | 42908.65 | 2.68 | 47.12 | 0 | 208856 |
| zig | 36885.76 | 3.41 | 348.61 | 10 | 1032 |

Zig at c=200 is a raw `accept` + `Thread.spawn` per connection with no pool. It drops connections (median 10 wrk socket errors; rounds were 10 / 11 / 0) and the tail blows out. That is a Zig harness limit, not a slang win to lean on.

### HTTP vs peers (median)

Need **higher RPS or lower p99, and lower RSS** to call a win vs Go. Need ~10% of C on RPS/p99. Need faster compile than Rust **and** p99/RSS no worse.

| vs | c=50 | c=200 | compile | result |
|---|---|---|---|---|
| C | RPS 26% lower (73801 / 100237); p99 62× worse (84.4 / 1.36); RSS 33× | RPS 21% lower; p99 18× worse; RSS 33× | slang 0.41s vs C 0.08s | **lose** |
| Go | RPS +9%; p50 better; p99 27× worse (84.4 / 3.09); RSS 3.9× | RPS +21%; p50 better; p99 8.3× worse; RSS 3.1× | slang 0.41s vs Go 3.74s (cold cache) | **lose** (RPS up, tail and RSS down) |
| Rust | RPS 5% lower (73801 / 77805); p99 73× worse; RSS 14× | RPS +5%; p99 20× worse; RSS 12× | slang 0.41s vs 10.35s | compile wins; **RPS/p99/RSS lose** at c=50 |
| Java | RPS 1.7×; p99 12× worse; RSS 6.5× better | RPS 1.8×; p99 4.2× worse; RSS 6.3× better | similar (0.41 vs 0.40) | beats Java on RPS and RSS; loses p99 |
| Zig | RPS 2.0×; p99 41× worse; RSS 82× worse | RPS 2.1×; Zig errors + p99 349ms | slang 0.41s vs 4.77s | higher RPS, much worse RSS; Zig c=200 is broken |
| C# | RPS 1.7×; p99 worse (84.4 vs 32.23); RSS 3.5× better | RPS 1.8×; p99 worse (70.47 vs 47.12); RSS 3.6× better | similar (0.41 vs 0.70) | beats C# on RPS and RSS; **loses p99** |

### HTTP vs previous remasure (PR #9, slang)

| metric | prev | new | delta |
|---|---:|---:|---|
| c=50 rps | 80692.13 | 73800.51 | −8.5% |
| c=50 p99_ms | 15.52 | 84.4 | 5.4× worse |
| c=50 rss_kb | 60560 | 58028 | −4% |
| c=200 rps | 85751.48 | 79228.57 | −8% |
| c=200 p99_ms | 16.59 | 70.47 | 4.2× worse |
| c=200 rss_kb | 61872 | 58744 | −5% |

Peer HTTP medians moved only a little (C c=50 RPS 105133 → 100237; Rust 76640 → 77805; Go 69216 → 67788). slang's p99 change is not explained by the box getting slower.

## Verdict

| comparison | result |
|---|---|
| Compute vs C | **lose** — 1.18× wall, higher RSS. C alloc is not a map, but C still finishes first. |
| Compute vs Rust | **lose** — 1.15× wall, higher RSS. Same algorithm (threads + `HashMap<String,_>`). |
| Compute vs Go | faster wall (0.68×); **lose RSS** (2.4×). Not a clean win. |
| Compute vs Java / Zig / C# | faster wall than all three. RSS beats Java and C#, loses to Zig. |
| HTTP vs C (~10% RPS/p99) | **lose** — 21–26% lower RPS; p99 18–62× worse; RSS ~33×. |
| HTTP vs Go (RPS or p99, **and** RSS) | **lose** — RPS is higher; p99 and RSS are worse. |
| HTTP vs Rust (faster compile; p99/RSS no worse) | **lose** — compile 0.41s vs 10.35s; c=50 RPS now loses; p99 and RSS lose. |
| HTTP vs Java / C# | higher RPS and lower RSS than both; **loses p99 to both**. |
| HTTP vs Zig | higher RPS; Zig RSS is tiny; Zig c=200 errors. Not a framework-fair fight. |
| vs previous slang remasure | compute wall **improved** (60 → 46 ms); HTTP RPS **down** and p99 **much worse**. Not a request-path win. |

Narrow facts, not overall wins:

- slang compute no longer SIGSEGVs at `-O3 -flto` on this workload.
- slang compute median wall is closer to C/Rust than in PR #9 (1.18× / 1.15× vs 1.43× / 1.25×).
- slang HTTP median RPS still beats Go, Java, Zig, and C# at both concurrencies. It no longer beats Rust at c=50.
- slang HTTP compiles much faster than tokio/axum (0.41s vs 10.35s).
- C still owns HTTP RPS, p99, and RSS. Rust owns HTTP tail latency among the managed/async servers, and now also c=50 RPS vs slang.
- slang HTTP RSS (~58 MB) is still the standout loss vs C / Rust / Go. The request-path cuts did not fix it.
- slang HTTP p99 is the standout regression vs PR #9 (15.52 ms → 84.4 ms at c=50). All three rounds were bad (66.97 / 84.4 / 106.51). Do not paper over that.

No LLVM. No slang syntax changes. Bench programs, wrk flags, body size, conc, duration, and the 8-worker floor are unchanged. `net.listen` / `net.recv` / `i32` fd APIs unchanged. Server types stay `wire` / `until` / `fault` / `peer` / `trip` / `link`.
