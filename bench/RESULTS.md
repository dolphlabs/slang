# Phase E HTTP-only remasure (`c5aacc1`, after #21+#23+#25)

HTTP-only remasure on this Linux VM at `c5aacc1` (`Merge pull request #25 from dolphlabs/feat/spawn-copy-args`). Intern / `M_ARENA_MAX` / arena freelist / interned for-in / `io_wake` remain **reverted**. Compute was **not** rerun. #20 keep-alive is in-tree on stdlib `http.read` but this bench still uses raw `link` + `Connection: close`, so keep-alive is not measured.

**slang does not win Phase E HTTP vs Go / C / Rust.** Median c=50 p99 is **5.99 ms** (rounds 6.32 / 5.99 / 5.81) and RSS is **18872 kB** (~18 MB). That is better than PR #9 (**15.52 ms**, ~59 MB) and the last remasure at `545d99b` (**23.02 ms**, ~56–62 MB), but p99 and RSS still lose to Go (2.84 ms / 15228 kB), C (1.62 ms / 1784 kB), and Rust (2.29 ms / 4148 kB). RPS beating Go / Java / Zig / C# is not a win.

Question this run answers: **#21+#23+#25 did move p99 and RSS.** Worker pool is now `ncpu` (this VM is 4 cores; the old 8-worker floor is gone). Median c=50 p99 dropped 23.02 → 5.99 ms; RSS dropped ~56–62 MB → ~18–21 MB. It is still a lose vs Go / C / Rust on both.

Do not treat higher RPS than Go / Java / Zig / C# as a win. The file's own HTTP win conditions need p99 **and** RSS, and slang has neither vs Go / C / Rust.

Measured SHA: `c5aacc1e3fde952c51fa813e716a25d96dac3dc3`. Branch: `async-preemption` `c5aacc1` + this RESULTS commit. Log/TSV: `/tmp/slang_phase_e_http`.

| commit | in this run? |
|---|---|
| `1c25b07` interned `b"..."` + `M_ARENA_MAX=2` | **no** (reverted by `545d99b`) |
| `9c1763b` arena freelist | **no** (reverted by `8bedecc`) |
| `2f7c20e` cheap interned bytes for-in | **no** (reverted by `8bedecc`) |
| `c4cc103` skip async preempt after reactor I/O wake | **no** (reverted by `fb39867`) |
| #20 keep-alive on stdlib `http.read` | in tree; **not exercised** (bench uses raw `link`, `Connection: close`) |
| #21 `getaddrinfo` off the worker pool; pool sized to `ncpu` | **yes** |
| #23 scalar `result[T,E]` is a stack value | **yes** |
| #25 non-GC `spawn` args copied into the task | **yes** |

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-09-06 19:49 |
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
| `git rev-parse HEAD` (measured tree) | `c5aacc1e3fde952c51fa813e716a25d96dac3dc3` |
| worker pool | `ncpu` = 4 (old 8-worker floor is gone) |

No language was skipped. slang HTTP did not SIGSEGV. Zig compiled; c=200 still errors (harness limit). First-round Rust (and C at c=200) RPS is a cold-start outlier; medians use n=3.

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
- Go / Rust / Zig / C# compile seconds are cold-cache on this boot. Do not treat that as a slang compile win.

## HTTP

GET `/`, 200-byte `text/plain` body, `Connection: close`, no TLS. slang / C / Zig write HTTP/1.0 bytes. Go `net/http`, Rust axum, Java `HttpServer`, and C# `HttpListener` speak HTTP/1.1; body length was 200 on every probe.

`wrk -t4 -c{50,200} -d10s --latency` (threads = min(nproc, conc)). 3 rounds.

### Compile times (seconds)

| slang | go | cc -O3 -flto | rust axum release | javac | zig ReleaseFast | dotnet publish |
|---:|---:|---:|---:|---:|---:|---:|
| 0.45 | 2.49 | 0.08 | 11.12 | 0.50 | 6.94 | 1.89 |

### Per-round, c=50

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 86746.26 | 0.364 | 6.32 | 0 | 18088 | 200 |
| 1 | go | 69248.62 | 0.492 | 2.78 | 0 | 14904 | 200 |
| 1 | c | 102340.09 | 0.209 | 1.38 | 0 | 1784 | 200 |
| 1 | rust | 49437.97 | 0.91 | 1.6 | 0 | 4168 | 200 |
| 1 | java | 30773.89 | 1.26 | 8.73 | 0 | 374788 | 200 |
| 1 | zig | 36695.16 | 1.23 | 2.12 | 0 | 632 | 200 |
| 1 | csharp | 34472.39 | 0.818 | 51.84 | 0 | 204400 | 200 |
| 2 | slang | 84652.90 | 0.373 | 5.99 | 0 | 19316 | 200 |
| 2 | csharp | 41302.95 | 0.69 | 35.69 | 0 | 205084 | 200 |
| 2 | zig | 37044.66 | 1.22 | 2.2 | 0 | 692 | 200 |
| 2 | java | 44118.98 | 0.765 | 5.55 | 0 | 389008 | 200 |
| 2 | rust | 73605.81 | 0.485 | 3.07 | 0 | 4148 | 200 |
| 2 | c | 99176.66 | 0.281 | 1.65 | 0 | 1784 | 200 |
| 2 | go | 67671.02 | 0.482 | 3.98 | 0 | 15792 | 200 |
| 3 | c | 103373.18 | 0.224 | 1.62 | 0 | 1788 | 200 |
| 3 | rust | 75849.38 | 0.49 | 2.29 | 0 | 4144 | 200 |
| 3 | java | 36122.15 | 0.95 | 7.19 | 0 | 373340 | 200 |
| 3 | zig | 36625.49 | 1.24 | 2.14 | 0 | 720 | 200 |
| 3 | csharp | 42911.91 | 0.674 | 33.15 | 0 | 204876 | 200 |
| 3 | slang | 89463.72 | 0.352 | 5.81 | 0 | 18872 | 200 |
| 3 | go | 67383.43 | 0.504 | 2.84 | 0 | 15228 | 200 |

### Per-round, c=200

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 91627.04 | 1.4 | 9.09 | 0 | 20924 | 200 |
| 1 | go | 70080.63 | 2.27 | 7.06 | 0 | 17452 | 200 |
| 1 | c | 82882.22 | 1.13 | 5.99 | 0 | 1784 | 200 |
| 1 | rust | 53878.60 | 2.06 | 10.32 | 0 | 4632 | 200 |
| 1 | java | 35506.33 | 4.99 | 18.08 | 0 | 365724 | 200 |
| 1 | zig | 37723.80 | 3.32 | 264.69 | 11 | 852 | 200 |
| 1 | csharp | 43440.35 | 2.71 | 39.48 | 0 | 204736 | 200 |
| 2 | slang | 88163.47 | 1.46 | 9.45 | 0 | 20112 | 200 |
| 2 | csharp | 41848.68 | 2.73 | 44.9 | 0 | 204516 | 200 |
| 2 | zig | 38013.91 | 3.31 | 209.78 | 9 | 840 | 200 |
| 2 | java | 40070.60 | 4.1 | 17.22 | 0 | 377108 | 200 |
| 2 | rust | 77952.95 | 1.27 | 4.69 | 0 | 4828 | 200 |
| 2 | c | 103068.86 | 0.92 | 3.95 | 0 | 1784 | 200 |
| 2 | go | 68031.49 | 2.39 | 8.95 | 0 | 18760 | 200 |
| 3 | c | 102408.07 | 0.9 | 3.96 | 0 | 1784 | 200 |
| 3 | rust | 77134.18 | 1.36 | 4.74 | 0 | 4812 | 200 |
| 3 | java | 41831.20 | 4.04 | 14.95 | 0 | 379108 | 200 |
| 3 | zig | 37498.48 | 3.35 | 328.76 | 6 | 1176 | 200 |
| 3 | csharp | 42554.96 | 2.7 | 45.14 | 0 | 209044 | 200 |
| 3 | slang | 91305.93 | 1.41 | 9.96 | 0 | 20636 | 200 |
| 3 | go | 70368.56 | 2.26 | 7.29 | 0 | 19148 | 200 |

### Medians (n=3)

c=50

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 102340.09 | 0.224 | 1.62 | 0 | 1784 |
| slang | 86746.26 | 0.364 | 5.99 | 0 | 18872 |
| rust | 73605.81 | 0.49 | 2.29 | 0 | 4148 |
| go | 67671.02 | 0.492 | 2.84 | 0 | 15228 |
| csharp | 41302.95 | 0.69 | 35.69 | 0 | 204876 |
| zig | 36695.16 | 1.23 | 2.14 | 0 | 692 |
| java | 36122.15 | 0.95 | 7.19 | 0 | 374788 |

c=200

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 102408.07 | 0.92 | 3.96 | 0 | 1784 |
| slang | 91305.93 | 1.41 | 9.45 | 0 | 20636 |
| rust | 77134.18 | 1.36 | 4.74 | 0 | 4812 |
| go | 70080.63 | 2.27 | 7.29 | 0 | 18760 |
| csharp | 42554.96 | 2.71 | 44.9 | 0 | 204736 |
| java | 40070.60 | 4.1 | 17.22 | 0 | 377108 |
| zig | 37723.80 | 3.32 | 264.69 | 9 | 852 |

Zig at c=200 is a raw `accept` + `Thread.spawn` per connection with no pool. It drops connections (median 9 wrk socket errors; rounds 11 / 9 / 6) and the tail blows out. That is a Zig harness limit, not a slang win to lean on.

Rust round-1 RPS (49438 at c=50, 53879 at c=200) and C round-1 c=200 RPS (82882) are cold. slang p99 stayed in the 5.8–6.3 ms band at c=50 and 9.1–10.0 ms at c=200 on every round.

### HTTP vs peers (median)

Need **higher RPS or lower p99, and lower RSS** to call a win vs Go. Need ~10% of C on RPS/p99. Need faster compile than Rust **and** p99/RSS no worse.

| vs | c=50 | c=200 | compile | result |
|---|---|---|---|---|
| C | RPS 15% lower (86746 / 102340); p99 3.7× worse (5.99 / 1.62); RSS 10.6× | RPS 11% lower; p99 2.4× worse; RSS 11.6× | slang 0.45s vs C 0.08s | **lose** |
| Go | RPS +28%; p50 better; p99 2.1× worse; RSS 1.24× | RPS +30%; p50 better; p99 1.3× worse; RSS 1.10× | slang 0.45s vs Go 2.49s (cold cache) | **lose** (RPS up, tail and RSS down) |
| Rust | RPS +18%; p99 2.6× worse; RSS 4.5× | RPS +18%; p99 2.0× worse; RSS 4.3× | slang 0.45s vs 11.12s | compile wins; **p99 and RSS lose** |
| Java | RPS 2.4×; p99 better (5.99 / 7.19); RSS 20× better | RPS 2.3×; p99 better; RSS 18× better | similar (0.45 vs 0.50) | beats Java on RPS, p99, and RSS — **not** a Phase E win |
| Zig | RPS 2.4×; p99 2.8× worse; RSS 27× worse | RPS 2.4×; Zig errors + p99 265 ms | slang 0.45s vs 6.94s | higher RPS, much worse RSS; Zig c=200 is broken |
| C# | RPS 2.1×; p99 better (5.99 vs 35.69); RSS 11× better | RPS 2.1×; p99 better; RSS 10× better | slang 0.45s vs 1.89s | beats C# on RPS, p99, RSS |

### slang vs PR #9 / `545d99b`

| metric | PR #9 (`a64f079`) | last remasure (`545d99b`) | this run (`c5aacc1`) | vs #9 | vs `545d99b` |
|---|---:|---:|---:|---|---|
| c=50 rps | 80692 | 73841 | 86746 | +7.5% | +17.5% |
| c=50 p99_ms | 15.52 | 23.02 | 5.99 | 2.6× better | 3.8× better |
| c=50 rss_kb | 60560 | 56548 | 18872 | −69% | −67% |
| c=200 rps | 85751 | 80534 | 91306 | +6.5% | +13.4% |
| c=200 p99_ms | 16.59 | 23.37 | 9.45 | 1.8× better | 2.5× better |
| c=200 rss_kb | 61872 | 61660 | 20636 | −67% | −67% |

## Verdict

| comparison | result |
|---|---|
| vs C | **lose** — 11–15% lower RPS; p99 2.4–3.7×; RSS ~11× |
| vs Go | **lose** — RPS up; p99 and RSS worse (RSS gap is now 1.10–1.24×, not 3–4×) |
| vs Rust | **lose** — compile faster; p99 and RSS lose |
| vs Java / C# | RPS, p99, and RSS better than both |
| vs Zig | higher RPS; Zig RSS tiny; Zig c=200 errors (median 9) |
| vs PR #9 | RPS up, p99 2.6× better (6 vs 16 ms), RSS −69% — **still lose p99/RSS vs Go / C / Rust** |
| vs `545d99b` | RPS up, p99 3.8× better (6 vs 23 ms), RSS −67% — **#21+#23+#25 moved p99/RSS; did not win Phase E** |

No language skipped. No slang SIGSEGV. Zig compiled; c=200 still drops connections. No LLVM. Worker pool is `ncpu` (4), not the old 8-worker floor. HTTP only. No slang syntax or bench changes.

---

# Phase E HTTP-only remasure (`545d99b`, PR #9-equivalent tree)

HTTP-only remasure on this Linux VM at `545d99b` (`Revert "perf(codegen): intern bytes literals and cap glibc malloc arenas"`). Every post-#9 request-path experiment is off: interned `b"..."` + `M_ARENA_MAX`, arena freelist, interned for-in, and `io_wake`. Compute was **not** rerun.

**slang does not win Phase E HTTP vs Go / C / Rust.** A true PR #9-equivalent HTTP tree did **not** restore the ~15 ms p99. Median c=50 p99 is **23.02 ms** (rounds 21.78 / 23.02 / 28.46) vs PR #9 **15.52** and PR #13 **105.97**. RPS is below #9 and above #13. RSS is a few percent below #9 (~56–62 MB) and still 3–32× Go / C / Rust.

Question this run answers: dropping intern + `M_ARENA` **does** recover the #13 ~100 ms tail down to the ~20 ms class, but it does **not** bring back the #9 15 ms number. That is still a lose vs Go / C / Rust on p99 and RSS.

Do not treat higher RPS than Go / Java / Zig / C# as a win. The file's own HTTP win conditions need p99 **and** RSS, and slang has neither vs Go / C / Rust.

Measured SHA: `545d99b738dd1c185bdc72d7e69b6dfc12c68fb7` (`cursor/http-remeasure-pr9-equiv-b546` RESULTS commit is after this tree). Branch: `async-preemption` `545d99b` + this RESULTS commit. Log/TSV: `/tmp/slang_phase_e_http`.

| commit | in this run? |
|---|---|
| `1c25b07` interned `b"..."` + `M_ARENA_MAX=2` | **no** (reverted by `545d99b`) |
| `9c1763b` arena freelist | **no** (reverted by `8bedecc`) |
| `2f7c20e` cheap interned bytes for-in | **no** (reverted by `8bedecc`) |
| `c4cc103` skip async preempt after reactor I/O wake | **no** (reverted by `fb39867`) |

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-09-06 18:34 |
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
| `git rev-parse HEAD` (measured tree) | `545d99b738dd1c185bdc72d7e69b6dfc12c68fb7` |

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
| 0.48 | 5.81 | 0.08 | 11.62 | 0.49 | 6.94 | 1.73 |

### Per-round, c=50

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 74544.38 | 0.437 | 21.78 | 0 | 60416 | 200 |
| 1 | go | 65533.18 | 0.523 | 2.66 | 0 | 14612 | 200 |
| 1 | c | 99600.11 | 0.218 | 1.27 | 0 | 1784 | 200 |
| 1 | rust | 74937.99 | 0.512 | 1.11 | 0 | 4224 | 200 |
| 1 | java | 38749.44 | 0.87 | 6.31 | 0 | 372596 | 200 |
| 1 | zig | 36828.48 | 1.22 | 2.54 | 0 | 696 | 200 |
| 1 | csharp | 36283.16 | 0.741 | 54.01 | 0 | 208840 | 200 |
| 2 | slang | 73841.44 | 0.441 | 23.02 | 0 | 56408 | 200 |
| 2 | csharp | 36731.34 | 0.735 | 46.9 | 0 | 204976 | 200 |
| 2 | zig | 36027.83 | 1.25 | 2.53 | 0 | 728 | 200 |
| 2 | java | 42490.02 | 0.817 | 6.05 | 0 | 447880 | 200 |
| 2 | rust | 69430.28 | 0.533 | 1.8 | 0 | 4276 | 200 |
| 2 | c | 95659.62 | 0.247 | 1.37 | 0 | 1780 | 200 |
| 2 | go | 64475.63 | 0.522 | 3.34 | 0 | 15148 | 200 |
| 3 | c | 93694.72 | 0.238 | 1.72 | 0 | 1788 | 200 |
| 3 | rust | 72772.72 | 0.513 | 2.13 | 0 | 4152 | 200 |
| 3 | java | 36558.38 | 0.96 | 6.89 | 0 | 372000 | 200 |
| 3 | zig | 35637.71 | 1.26 | 2.26 | 0 | 780 | 200 |
| 3 | csharp | 35408.24 | 0.774 | 52.13 | 0 | 204776 | 200 |
| 3 | slang | 69243.97 | 0.461 | 28.46 | 0 | 56548 | 200 |
| 3 | go | 54458.22 | 0.621 | 3.38 | 0 | 15200 | 200 |

### Per-round, c=200

| round | lang | rps | p50_ms | p99_ms | errors | rss_kb | body |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | slang | 80533.85 | 1.66 | 23.37 | 0 | 61660 | 200 |
| 1 | go | 65954.45 | 2.39 | 7.32 | 0 | 19164 | 200 |
| 1 | c | 100999.36 | 0.93 | 3.93 | 0 | 1784 | 200 |
| 1 | rust | 72227.63 | 1.43 | 3.49 | 0 | 4956 | 200 |
| 1 | java | 42391.90 | 4.1 | 15.49 | 0 | 374368 | 200 |
| 1 | zig | 36868.50 | 3.41 | 304.18 | 1 | 1312 | 200 |
| 1 | csharp | 38035.17 | 2.88 | 53.29 | 0 | 204832 | 200 |
| 2 | slang | 76996.19 | 1.74 | 24.16 | 0 | 60828 | 200 |
| 2 | csharp | 42746.54 | 2.71 | 42.95 | 0 | 204932 | 200 |
| 2 | zig | 36209.93 | 3.46 | 172.5 | 37 | 1032 | 200 |
| 2 | java | 40462.97 | 4.22 | 16.04 | 0 | 377048 | 200 |
| 2 | rust | 74109.07 | 1.37 | 4.71 | 0 | 4804 | 200 |
| 2 | c | 94006.07 | 1.01 | 4.21 | 0 | 1784 | 200 |
| 2 | go | 61959.73 | 2.55 | 8.23 | 0 | 20484 | 200 |
| 3 | c | 98242.03 | 0.94 | 4.02 | 0 | 1784 | 200 |
| 3 | rust | 72756.43 | 1.45 | 3.52 | 0 | 4660 | 200 |
| 3 | java | 43065.55 | 4.09 | 13.14 | 0 | 417072 | 200 |
| 3 | zig | 33735.13 | 3.71 | 585.7 | 2 | 888 | 200 |
| 3 | csharp | 40638.06 | 2.75 | 45.9 | 0 | 210268 | 200 |
| 3 | slang | 80676.22 | 1.66 | 23.07 | 0 | 62040 | 200 |
| 3 | go | 65064.76 | 2.47 | 8.45 | 0 | 17824 | 200 |

### Medians (n=3)

c=50

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 95659.62 | 0.238 | 1.37 | 0 | 1784 |
| slang | 73841.44 | 0.441 | 23.02 | 0 | 56548 |
| rust | 72772.72 | 0.513 | 1.8 | 0 | 4224 |
| go | 64475.63 | 0.523 | 3.34 | 0 | 15148 |
| java | 38749.44 | 0.87 | 6.31 | 0 | 372596 |
| csharp | 36283.16 | 0.741 | 52.13 | 0 | 204976 |
| zig | 36027.83 | 1.25 | 2.53 | 0 | 728 |

c=200

| lang | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---:|---:|---:|---:|---:|
| c | 98242.03 | 0.94 | 4.02 | 0 | 1784 |
| slang | 80533.85 | 1.66 | 23.37 | 0 | 61660 |
| rust | 72756.43 | 1.43 | 3.52 | 0 | 4804 |
| go | 65064.76 | 2.47 | 8.23 | 0 | 19164 |
| java | 42391.90 | 4.1 | 15.49 | 0 | 377048 |
| csharp | 40638.06 | 2.75 | 45.9 | 0 | 204932 |
| zig | 36209.93 | 3.46 | 304.18 | 2 | 1032 |

Zig at c=200 is a raw `accept` + `Thread.spawn` per connection with no pool. It drops connections (median 2 wrk socket errors; rounds 1 / 37 / 2) and the tail blows out. That is a Zig harness limit, not a slang win to lean on.

This box's C / Go / Rust RPS is a few percent below the PR #9 rows (C 95660 vs 105133 at c=50). slang p99 is still in the 22–28 ms band on every round, not 15 ms.

### HTTP vs peers (median)

Need **higher RPS or lower p99, and lower RSS** to call a win vs Go. Need ~10% of C on RPS/p99. Need faster compile than Rust **and** p99/RSS no worse.

| vs | c=50 | c=200 | compile | result |
|---|---|---|---|---|
| C | RPS 23% lower (73841 / 95660); p99 16.8× worse (23.02 / 1.37); RSS 32× | RPS 18% lower; p99 5.8× worse; RSS 35× | slang 0.48s vs C 0.08s | **lose** |
| Go | RPS +14%; p50 better; p99 6.9× worse; RSS 3.7× | RPS +24%; p50 better; p99 2.8× worse; RSS 3.2× | slang 0.48s vs Go 5.81s (cold cache) | **lose** (RPS up, tail and RSS down) |
| Rust | RPS +1.5%; p99 12.8× worse; RSS 13.4× | RPS +11%; p99 6.6× worse; RSS 12.8× | slang 0.48s vs 11.62s | compile wins; **p99 and RSS lose** |
| Java | RPS 1.9×; p99 3.6× worse; RSS 6.6× better | RPS 1.9×; p99 1.5× worse; RSS 6.1× better | similar (0.48 vs 0.49) | beats Java on RPS and RSS; **lose p99** |
| Zig | RPS 2.0×; p99 9.1× worse; RSS 78× worse | RPS 2.2×; Zig errors + p99 304 ms | slang 0.48s vs 6.94s | higher RPS, much worse RSS; Zig c=200 is broken |
| C# | RPS 2.0×; p99 better (23.02 vs 52.13); RSS 3.6× better | RPS 2.0×; p99 better; RSS 3.3× better | slang 0.48s vs 1.73s | beats C# on RPS, p99, RSS |

### slang vs PR #9 / #13

| metric | PR #9 (`a64f079`) | PR #13 (`8bedecc`, intern on) | this run (`545d99b`) | vs #9 | vs #13 |
|---|---:|---:|---:|---|---|
| c=50 rps | 80692 | 69965 | 73841 | −8.5% | +5.5% |
| c=50 p99_ms | 15.52 | 105.97 | 23.02 | 1.48× worse | 4.6× better |
| c=50 rss_kb | 60560 | 57764 | 56548 | −6.6% | −2.1% |
| c=200 rps | 85751 | 73257 | 80534 | −6.1% | +9.9% |
| c=200 p99_ms | 16.59 | 88.69 | 23.37 | 1.41× worse | 3.8× better |
| c=200 rss_kb | 61872 | 58804 | 61660 | ~same | +4.9% |

## Verdict

| comparison | result |
|---|---|
| vs C | **lose** — 18–23% lower RPS; p99 6–17×; RSS ~32–35× |
| vs Go | **lose** — RPS up; p99 and RSS worse |
| vs Rust | **lose** — compile faster; p99 and RSS lose |
| vs Java / C# | RPS and RSS better than both; p99 beats C#, **loses to Java** |
| vs Zig | higher RPS; Zig RSS tiny; Zig c=200 errors (median 2) |
| vs PR #9 | RPS down, p99 1.4–1.5× worse (23 vs 15 ms), RSS slightly better — **15 ms tail did not return** |
| vs PR #13 | RPS up, p99 much better (23 vs 106 / 89 ms), RSS ~same — intern revert **improved** the tail, did not **win** Phase E |

No language skipped. No slang SIGSEGV. Zig compiled; c=200 still drops connections. No LLVM. 8-worker floor unchanged. HTTP only. No slang syntax or bench changes.

---

# Phase E results (rerun)

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
