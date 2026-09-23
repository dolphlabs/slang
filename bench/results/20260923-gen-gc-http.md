# Gen-GC HTTP remasure — 2026-09-23 (Cursor cloud VM)

Remasure of slang generational GC vs Go/Rust on raw-throughput and
real-server axes at `origin/dev` tip. Axes not mixed. Rust/axum not on
the real-server axis.

## Host

```
Linux cursor 6.12.94+ #1 SMP PREEMPT_DYNAMIC Mon Sep 21 15:10:15 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
PRETTY_NAME="Ubuntu 24.04.4 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.4 LTS (Noble Numbat)"
VERSION_CODENAME=noble
CPU(s):                                  4
Model name:                              Intel(R) Xeon(R) Processor
Thread(s) per core:                      1
Core(s) per socket:                      4
Socket(s):                               1
NUMA node(s):                            1
NUMA node0 CPU(s):                       0-3
nproc=4
               total        used        free      shared  buff/cache   available
Mem:            15Gi       8.7Gi       6.5Gi       9.2Mi       633Mi       6.9Gi
Swap:             0B          0B          0B
/dev/vdc        254G  6.6G  247G   3% /
NAME  SIZE TYPE ROTA MODEL
vda   256G disk    1
vdb   256G disk    1
vdc   256G disk    1
```

`HOST_NOTE: user waived 16c/32G requirement; ran on Cursor cloud VM as given.`

Numbers are not comparable to a quiet 16c/32G dedicated host.

## Checkout / toolchains / wall-clock

| field | value |
|---|---|
| SHA | `00ec32fd5ecfff560ca2031c44a6d5796a0eae35` (`origin/dev`) |
| tip commit | Merge pull request #205 from dolphlabs/gc-followup-verify |
| go | go1.22.2 linux/amd64 |
| rustc | 1.83.0 (90b35a623 2024-11-26) |
| cargo | 1.83.0 (5ffbef321 2024-10-29) |
| clang | Ubuntu clang version 18.1.3 (1ubuntu1) |
| wrk | debian/4.1.0-4build2 (stock `apt install wrk`) |
| time | GNU time 1.9 (`apt install time`; `/usr/bin/time` required by bench scripts) |
| START | `2026-09-23T23:18:03Z` |
| END | `2026-09-23T23:27:58Z` |

Build policy: `make slangc` only; Go `go build` via scripts; Rust
`cargo build --release` via scripts; stock flags only.

## Axis A — raw-throughput medians

`HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http_opt.sh`

Script defaults: `HTTP_ACCEPTORS=$(nproc)=4`, `SLANG_PREEMPT_QUANTUM_MS=50`,
`SLANG_PREEMPT_TICK_MS=10`. Loadgen: `wrk`. Ports 18190–18193.
Output: `/tmp/slang_http_opt/`.

```
-- medians --
go_raw c=50 rps=80912.10 p50_ms=0.396 p99_ms=1.47 errors=0 rss_kb=10696 n=3
c c=200 rps=101218.29 p50_ms=0.92 p99_ms=3.98 errors=0 rss_kb=1784 n=3
slang_opt c=50 rps=92347.97 p50_ms=0.336 p99_ms=1.05 errors=0 rss_kb=3088 n=3
rust_raw c=200 rps=87927.72 p50_ms=1.04 p99_ms=2.89 errors=0 rss_kb=3644 n=3
slang_opt c=200 rps=94855.97 p50_ms=1.34 p99_ms=5.18 errors=0 rss_kb=4928 n=3
c c=50 rps=102354.67 p50_ms=0.218 p99_ms=1.19 errors=0 rss_kb=1780 n=3
go_raw c=200 rps=87431.99 p50_ms=1.6 p99_ms=5.32 errors=0 rss_kb=11612 n=3
rust_raw c=50 rps=79560.17 p50_ms=0.444 p99_ms=1.1 errors=0 rss_kb=3264 n=3
```

compile_s: `slang_opt=0.62 go_raw=0.10 cc_O3_lto=0.08 rust_tokio_raw=6.74`

### `/tmp/slang_http_opt/runs.tsv`

```
slang_opt	1	50	96941.04	0.323	1.01	0	3076
slang_opt	1	200	94933.15	1.3	5.18	0	4788
go_raw	1	50	79221.98	0.406	1.51	0	10696
go_raw	1	200	87431.99	1.6	5.39	0	11612
c	1	50	102354.67	0.209	1.49	0	1780
c	1	200	101218.29	0.92	3.97	0	1784
rust_raw	1	50	85550.59	0.416	1.03	0	3316
rust_raw	1	200	90677.23	1.02	3.08	0	3540
slang_opt	2	50	90899.77	0.342	1.05	0	3096
slang_opt	2	200	94855.97	1.34	5.11	0	4988
rust_raw	2	50	79560.17	0.444	1.1	0	3256
rust_raw	2	200	87927.72	1.04	2.89	0	3644
c	2	50	101973.33	0.218	1.19	0	1776
c	2	200	100120.87	0.92	3.98	0	1784
go_raw	2	50	80912.10	0.396	1.47	0	10552
go_raw	2	200	88364.00	1.57	5.27	0	12056
c	3	50	102371.06	0.22	1.16	0	1784
c	3	200	101852.22	0.91	3.99	0	1780
rust_raw	3	50	78536.67	0.444	1.15	0	3264
rust_raw	3	200	85578.17	1.09	2.88	0	3708
slang_opt	3	50	92347.97	0.336	1.05	0	3088
slang_opt	3	200	94736.18	1.34	5.3	0	4928
go_raw	3	50	81733.05	0.392	1.47	0	10760
go_raw	3	200	87088.60	1.61	5.32	0	11368
```

### `/tmp/slang_http_opt/compile.txt`

```
0.62 0.10 0.08 6.74
```

## Axis B — real-server medians

`HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http_realserver.sh`

slang realserver vs Go `net/http` only. **No Rust/axum.**
Loadgen: `/tmp/http_loadgen -keepalive`. Ports 18201–18202.
Output: `/tmp/slang_http_realserver/`. `HTTP_ACCEPTORS=4`.

```
-- medians --
slang_realserver c=50 rps=94840.70 p50_ms=0.398 p99_ms=2.224 errors=0 rss_kb=5468 n=3
slang_realserver c=200 rps=93415.50 p50_ms=1.318 p99_ms=15.717 errors=0 rss_kb=8012 n=3
go_realserver c=200 rps=121205.60 p50_ms=1.343 p99_ms=5.953 errors=0 rss_kb=18868 n=3
go_realserver c=50 rps=119986.80 p50_ms=0.344 p99_ms=1.638 errors=0 rss_kb=14204 n=3
```

compile_s: `slang_realserver=1.21 go_net_http=0.22`

### `/tmp/slang_http_realserver/runs.tsv`

```
slang_realserver	1	50	94617.50	0.398	2.224	0	5588
slang_realserver	1	200	93415.50	1.318	15.717	0	8012
go_realserver	1	50	121774.10	0.339	1.599	0	14308
go_realserver	1	200	120171.40	1.370	5.953	0	16988
slang_realserver	2	50	94840.70	0.387	2.309	0	5468
slang_realserver	2	200	94516.70	1.148	17.813	0	8616
go_realserver	2	50	119986.80	0.344	1.646	0	14016
go_realserver	2	200	121834.70	1.336	6.044	0	18868
slang_realserver	3	50	95091.50	0.399	2.200	0	5376
slang_realserver	3	200	90301.10	1.510	13.515	0	7792
go_realserver	3	50	119555.90	0.345	1.638	0	14204
go_realserver	3	200	121205.60	1.343	5.911	0	19732
```

### `/tmp/slang_http_realserver/compile.txt`

```
1.21 0.22
```

## §4 SLANG_GC_STAT (slang only)

Throwaway `/tmp` copies of servers with `proc.shutdown_requested()` +
active-task drain (pattern `examples/httpd/main.sl` 38–46). No shipped
source edits. SIGTERM so destructor dumps stats. Fields reported:
collects, minor_collects, pause_ns_max, minor_pause_ns_max, marked,
swept, promoted (+ nursery_threshold for context).

### 4a — Axis A raw-opt (default nursery)

`HTTP_ACCEPTORS=4 SLANG_PREEMPT_QUANTUM_MS=50 SLANG_PREEMPT_TICK_MS=10 SLANG_GC_STAT=1`
Load: `wrk -t4 -c$conc -d10s --latency`. Port 18390.

| conc | collects | minor_collects | pause_ns_max | minor_pause_ns_max | marked | swept | promoted | nursery_threshold |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 524288 |
| 200 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 524288 |

Verbatim:

```
# c=50
slang-gc-stat collects=0 minor_collects=0 allocs=6 alloc_bytes=304 pause_ns_total=0 pause_ns_max=0 marked=0 swept=0 survived=0 cycle_allocs=0 threshold=8388608 minor_pause_ns_max=0 minor_swept=0 promoted=0 nursery_threshold=524288
# c=200
slang-gc-stat collects=0 minor_collects=0 allocs=6 alloc_bytes=304 pause_ns_total=0 pause_ns_max=0 marked=0 swept=0 survived=0 cycle_allocs=0 threshold=8388608 minor_pause_ns_max=0 minor_swept=0 promoted=0 nursery_threshold=524288
```

Zero collects on Axis A matches `send_static` (no GC allocs on the
request path beyond startup).

### 4b — Axis B realserver (default nursery)

`HTTP_ACCEPTORS=4 SLANG_GC_STAT=1`. Load: `/tmp/http_loadgen -keepalive -d 10s`.
Port 18401.

| conc | collects | minor_collects | pause_ns_max | minor_pause_ns_max | marked | swept | promoted | nursery_threshold |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 | 239 | 3596 | 1420372 | 2184368 | 6158 | 1782182 | 86416 | 524288 |
| 200 | 232 | 3491 | 2130640 | 3390056 | 5769 | 1728115 | 81699 | 524288 |

Verbatim:

```
# c=50
slang-gc-stat collects=239 minor_collects=3596 allocs=27505688 alloc_bytes=2010760042 pause_ns_total=229035607 pause_ns_max=1420372 marked=6158 swept=1782182 survived=6158 cycle_allocs=1788340 threshold=8388608 minor_pause_ns_max=2184368 minor_swept=25722623 promoted=86416 nursery_threshold=524288
# c=200
slang-gc-stat collects=232 minor_collects=3491 allocs=26705838 alloc_bytes=1952285882 pause_ns_total=262899860 pause_ns_max=2130640 marked=5769 swept=1728115 survived=5769 cycle_allocs=1733884 threshold=8388608 minor_pause_ns_max=3390056 minor_swept=24973176 promoted=81699 nursery_threshold=524288
```

Accompanying loadgen (not headline; diagnostics only):

```
c=50:  RESULT rps=94846.90 p50_ms=0.380 p99_ms=2.344 ok=948469 errors=0
c=200: RESULT rps=92087.90 p50_ms=1.445 p99_ms=13.720 ok=920879 errors=0
```

### 4c — Axis B 16KB nursery stress (NOT headline)

One run at **c=200** with `SLANG_GC_NURSERY_KB=16`. Port 18402.

| conc | collects | minor_collects | pause_ns_max | minor_pause_ns_max | marked | swept | promoted | nursery_threshold |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 42 | 21245 | 1881605 | 22515240 | 1846 | 637761 | 639676 | 16384 |

Verbatim:

```
slang-gc-stat collects=42 minor_collects=21245 allocs=4859072 alloc_bytes=355211626 pause_ns_total=65997990 pause_ns_max=1881605 marked=1846 swept=637761 survived=1846 cycle_allocs=639607 threshold=8388608 minor_pause_ns_max=22515240 minor_swept=4216117 promoted=639676 nursery_threshold=16384
```

Accompanying loadgen (stress only; not comparable to Axis B headline):

```
RESULT rps=16739.80 p50_ms=0.629 p99_ms=36.554 ok=167398 errors=143
```

## Deviations / build failures

1. First Axis A attempt failed because `/usr/bin/time` was missing
   (`time_sec` in `run_http_opt.sh`). Installed stock Ubuntu package
   `time` 1.9-0.2build1, then re-ran Axis A cleanly. No languages
   dropped; all four peers present in medians.
2. Installed stock `wrk` 4.1.0-4build2 (not previously present).
3. Host is ~4c / ~15G Cursor cloud VM; user explicitly waived 16c/32G
   host gate. Report host honestly; do not treat as quiet dedicated box.
4. No shipped bench sources edited. §4 used throwaway `/tmp` copies only.
5. No Rust/axum on Axis B (per prompt).
6. No language build failures on the successful runs.
7. §4 log interleaving: `LISTEN_PORT` (stdout) and `slang-gc-stat`
   (stderr) reorder under file redirect; post-load alloc counts match
   loadgen request volume, so captures are end-of-run destructor dumps.

## Method notes (three-axis rule)

- Axis A = raw-throughput (`http_opt` / go_raw / rust_raw / c). Same work.
- Axis B = real-server (slang `stdlib/http` vs Go `net/http`). Same work.
- Never compare across axes. Win condition is p99 **and** RSS; RPS alone
  is not a win (see `bench/http/README.md`).
