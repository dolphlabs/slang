# Phase E bench results (cloud Linux VM)

Collected 2026-09-06 on this VM. Numbers are from a real run of
`bench/run_compute.sh` and `bench/run_http.sh`. slang does **not** win
the Phase E goals on this machine.

## Machine

| | |
|---|---|
| OS | Linux 6.12.94+ x86_64 (`Linux cursor`) |
| CPU | 4× Intel Xeon (KVM), 1 thread/core, 4 cores |
| RAM | 15 GiB, no swap |
| `cc` | Ubuntu clang 18.1.3 |
| `gcc` | 13.3.0 |
| Go | go1.22.2 linux/amd64 |
| rustc / cargo | 1.83.0 |
| loadgen | wrk 4.1.0 (epoll), `-t$(nproc)` |
| slangc | built with `make slangc` (`-std=c11 -O2 -D_GNU_SOURCE`) |
| generated C | `cc -O3 -flto` (slangc default, Phase D) |
| git | `cursor/phase-e-bench-d903` at measurement time |

Linux-only portability used to get binaries to compile here (not Phase D
compiler work): `_GNU_SOURCE` on `slangc`, Linux `ucontext` RIP/RSP in
`runtime/sl_pool.c`.

## Exact commands / env

```sh
make slangc
CC_TASKS=200 CC_WORK=8000 CC_ALLOC=50 CC_ROUNDS=3 ./bench/run_compute.sh
HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http.sh
```

Pinned HTTP ports: slang `18180`, Go `18181`, C `18182`, Rust `18183`.
Servers killed with SIGTERM then SIGKILL between runs. Order rotates
each round. RSS is GNU `time` max RSS (compute) or `/proc/$pid/status`
`VmHWM` after wrk (HTTP), both in kB.

Workload:

- Compute: 200 tasks, primes in `[0, 8000)`, per-task list+map of 50
  elements (slang GC / Go maps / C malloc / Rust `HashMap`). Optional
  slang `bench/compute/arena.sl` uses `arena` + value loops only.
- HTTP: GET `/`, 200-byte body, `Connection: close`, no TLS. slang is
  `link_listen` + `arena`/`wire` + `spawn` per conn. Go is `net/http`.
  C is `epoll` + `SO_REUSEPORT` (ncpu threads) + 1 MiB bump arena.
  Rust is tokio + axum 0.7 (`cargo build --release` after `cargo fetch`
  + `cargo clean`).

---

## Compute

### Compile time (one timed build each)

| compiler | seconds |
|---|---|
| `slangc` (GC program, includes `cc -O3 -flto`) | **0.44** |
| `slangc` (`arena.sl`) | 0.37 |
| `go build` | **0.02** |
| `cc -O3 -std=c11` | **0.06** |
| `rustc --edition 2021 -C opt-level=3` | **0.22** |

slang loses compile time to Go, C, and rustc on this tiny program.

### Per-round runtime

| round | order | slang | go | c | rust |
|---|---|---|---|---|---|
| 1 | slang, go, c, rust | **SIGSEGV** rss=5720 | wall=85 rss=2680 tps=2352 | wall=40 rss=3280 tps=5000 | wall=40 rss=3936 tps=5000 |
| 2 | rust, c, go, slang | **SIGSEGV** rss=5512 | wall=68 rss=2572 tps=2941 | wall=37 rss=3152 tps=5405 | wall=40 rss=3964 tps=5000 |
| 3 | go, rust, slang, c | **SIGSEGV** rss=5832 | wall=68 rss=2700 tps=2941 | wall=39 rss=3240 tps=5128 | wall=39 rss=3584 tps=5128 |

All four that finished reported `total_primes=201400`. slang GC and
slang arena both died with `Command terminated by signal 11` at the
shipping `-O3 -flto` build.

### Medians (surviving runs)

| | wall_ms | rss_kb | tasks_per_sec | n |
|---|---|---|---|---|
| slang `-O3 -flto` | **crash** | — | — | 0/3 |
| go | 68 | 2680 | 2941 | 3 |
| c | 39 | 3240 | 5128 | 3 |
| rust | 40 | 3936 | 5000 | 3 |

### Footnote: slang `-O0` (not the Phase D config)

The same generated C compiled `cc -O0 -g` completed:

`wall_ms=171 rss_kb=6092 tasks_per_sec=1169 total_primes=201400`

That is slower than Go/C/Rust and higher RSS than Go. It is **not** a
Phase E win. `-O3` (no LTO) also SIGSEGV'd; only `-O0` ran to completion
on this VM.

### Compute verdict: **lose**

slang's shipping `-O3/LTO` binary crashes under this load on Linux.
Cannot claim a throughput or RSS win.

---

## HTTP

### Compile time (one timed build each)

| compiler | seconds |
|---|---|
| `slangc` `bench/http/main.sl` | **0.38** |
| `go build` `bench/http/main.go` | **0.06** |
| `cc -O3 -flto` `bench/http/main.c` | **0.07** |
| `cargo build --release` (axum+tokio, clean tree, deps already fetched) | **9.68** |

slang compiles much faster than rustc+LLVM+axum. slang compiles slower
than `go build` and `cc -O3 -flto` for these tiny servers.

### Per-round (wrk 10s, errors=0, body=200 on every probe)

**c=50**

| round | slang rps / p50 / p99 / rss | go | c | rust |
|---|---|---|---|---|
| 1 | 73327 / 0.478 / 23.23 / 66492 | 67986 / 0.503 / 2.65 / 15152 | 103205 / 0.215 / 1.22 / 1852 | 76209 / 0.509 / 1.09 / 4132 |
| 2 | 75025 / 0.467 / 20.14 / 66128 | 70080 / 0.495 / 2.71 / 14748 | 102850 / 0.211 / 1.27 / 1876 | 76353 / 0.507 / 1.09 / 4120 |
| 3 | 75327 / 0.468 / 20.04 / 66984 | 68370 / 0.508 / 2.66 / 14848 | 103571 / 0.215 / 1.15 / 1804 | 75915 / 0.504 / 1.10 / 4256 |

**c=200**

| round | slang rps / p50 / p99 / rss | go | c | rust |
|---|---|---|---|---|
| 1 | 78335 / 1.91 / 25.34 / 83644 | 69684 / 2.29 / 6.88 / 18824 | 103627 / 0.89 / 3.91 / 1788 | 75643 / 1.40 / 3.31 / 4664 |
| 2 | 80335 / 1.89 / 22.23 / 87604 | 69783 / 2.27 / 6.96 / 18300 | 104470 / 0.89 / 3.91 / 1856 | 76666 / 1.38 / 3.34 / 4748 |
| 3 | 80843 / 1.88 / 22.88 / 87776 | 70893 / 2.26 / 6.71 / 17916 | 104174 / 0.89 / 3.88 / 1792 | 76425 / 1.42 / 3.47 / 4888 |

p50/p99 in milliseconds. rss in kB.

### Medians

**c=50**

| | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---|---|---|---|---|
| slang | 75025 | 0.468 | 20.14 | 0 | 66492 |
| go | 68370 | 0.503 | 2.66 | 0 | 14848 |
| c | 103205 | 0.215 | 1.22 | 0 | 1852 |
| rust | 76209 | 0.507 | 1.09 | 0 | 4132 |

**c=200**

| | rps | p50_ms | p99_ms | errors | rss_kb |
|---|---|---|---|---|---|
| slang | 80335 | 1.89 | 22.88 | 0 | 87604 |
| go | 69783 | 2.27 | 6.88 | 0 | 18300 |
| c | 104174 | 0.89 | 3.91 | 0 | 1792 |
| rust | 76425 | 1.40 | 3.34 | 0 | 4748 |

### Goal checks

1. **vs Go** — higher RPS *or* lower p99, **and** lower RSS at the same
   concurrency.
   - RPS: slang **higher** (c=50 +10%; c=200 +15%).
   - p99: slang **worse** (c=50 20.14 vs 2.66; c=200 22.88 vs 6.88).
   - RSS: slang **worse** (c=50 66 MB vs 15 MB; c=200 88 MB vs 18 MB).
   - Combined goal: **lose**.

2. **vs C arena** — slang within ~10% of C on RPS/p99.
   - RPS: slang is 27% slower at c=50 (75025/103205) and 23% slower at
     c=200 (80335/104174). Not within 10%.
   - p99: slang is ~16× worse at c=50 and ~6× worse at c=200.
   - **lose**.

3. **vs Rust tokio/axum** — slang faster compile; p99/RSS no worse than
   tokio. rustc+LLVM winning peak RPS is OK if compile+p99 still win.
   - Compile: slang **wins** (0.38s vs 9.68s).
   - Peak RPS: rust slightly ahead at c=50; slang slightly ahead at
     c=200. Allowed.
   - p99: slang **worse** (20.14 vs 1.09; 22.88 vs 3.34).
   - RSS: slang **worse** (66 MB vs 4.1 MB; 88 MB vs 4.7 MB).
   - Compile+p99: **lose** (compile wins, p99 does not).

### HTTP verdict: **lose** (with two real, narrower facts)

- slang **does** beat Go on median RPS at both concurrencies.
- slang **does** beat rustc+axum on compile time.

Those do not satisfy the stated Phase E comparisons once p99 and RSS
are included. C remains the speed ceiling on this VM.

---

## Overall verdict: **lose**

| comparison | result |
|---|---|
| Compute vs Go/C/Rust | **lose** (slang `-O3/LTO` SIGSEGV; `-O0` is slower) |
| HTTP vs Go (RPS or p99, and RSS) | **lose** (RPS only) |
| HTTP vs C (~10% RPS/p99) | **lose** |
| HTTP vs Rust (compile + p99/RSS) | **lose** (compile only) |

Not inconclusive: the measurements completed (except compute slang
crashes, which are themselves a result). slang is not the winner on
this Linux VM under these harnesses.
