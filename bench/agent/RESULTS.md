# Agent token benchmark — results

Results from `bench/agent/run.py`, measuring what it costs an LLM agent to
build five backend services (`auth`, `jobs`, `notes`, `ratelimit`, `upload`)
from scratch in four stacks (`slang-zokor`, `go-fiber`, `rust-axum`, `ts-nest`),
tested against hidden black-box HTTP acceptance suites (`tasks/*/accept.py`)
plus a 5-second `wrk` load check and process-group peak RSS sample.

Every row below comes from raw artifacts in run `20261126T181431Z`. Because
each task×stack cell was run once (`--runs 1`), treat small margins as
single-run variance rather than multi-run medians.

## Run `20261126T181431Z` (2026-11-26 – 2026-11-27, `--runs 1`)

### Environment & toolchains

| Field | Value |
|---|---|
| Host | MacBook Pro (`Intel(R) Core(TM) i5-8279U CPU @ 2.40GHz`, 4 cores / 8 threads, 16 GiB RAM, macOS 15.8.2) |
| Agent | Claude Code `2.1.322`, model `claude-opus-5-5` |
| `slangc` | `0.2.9` (`origin/dev` `f0e5b418`) with `zokor` (`v0.2.0` on `auth`/`jobs`/`notes`/`ratelimit`, `v0.2.1` on `upload`) |
| Go | `go1.27.4 darwin/amd64` with `github.com/gofiber/fiber/v2 v2.52.15` |
| Rust | `rustc 1.99.1` with `axum 0.8` + `tokio 1` (`--release`, LTO) |
| TypeScript | Node `v22.14.0` with `@nestjs/common` / `@nestjs/core` / `@nestjs/platform-express` `^11.0.0` |
| Load generator | `wrk 4.2.0` (`-t2 -c32 -d5s --latency`) |

### Summary by stack

Medians below are taken across all 5 passing tasks per stack:

| Stack | Tasks passed | Median total tokens | Median output tokens | Median turns | Total cost (USD) | Total non-test LOC | Median RPS | Median p99 (ms) | Median peak RSS (MB) | Binary size (`auth`) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `slang-zokor` | 5/5 | 765,111 | 7,540 | 12 | $5.45 | **705** | 46,154 | 10.17 | 9.6 | **867 KB** |
| `go-fiber` | 5/5 | 343,121 | 8,258 | 8 | $2.60 | 922 | 107,777 | **1.27** | 14.8 | 11 MB |
| `rust-axum` | 5/5 | **213,960** | **6,315** | **5** | **$2.19** | 1,032 | **115,350** | 1.84 | **3.5** | 1.3 MB |
| `ts-nest` | 5/5 | 460,506 | 11,659 | 10 | $3.49 | 1,705 | 5,424 | 18.11 | 170.0 | — (Node runtime) |

### Full results (all 20 runs)

| Task | Stack | Pass | Total tokens | Output tokens | Turns | Cost (USD) | RPS | p99 (ms) | Peak RSS (MB) | `wrk` endpoint |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `auth` | `go-fiber` | 1/1 | 343,121 | 8,258 | 8 | $0.53 | 117,728 | 0.64 | 15.1 | `GET /health` |
| `auth` | `rust-axum` | 1/1 | 213,960 | 6,979 | 5 | $0.46 | 115,664 | 0.69 | 3.4 | `GET /health` |
| `auth` | `slang-zokor` | 1/1 | 765,111 | **6,813** | 13 | $0.75 | 65,804 | 10.17 | 9.0 | `GET /health` |
| `auth` | `ts-nest` | 1/1 | 538,643 | 16,670 | 11 | $0.81 | 5,408 | 18.11 | 169.8 | `GET /health` |
| `jobs` | `go-fiber` | 1/1 | 446,879 | 11,842 | 10 | $0.63 | 110,548 | 1.27 | 14.6 | `GET /jobs/<id>` |
| `jobs` | `rust-axum` | 1/1 | 252,845 | 5,148 | 6 | $0.42 | 112,141 | 1.84 | 3.5 | `GET /jobs/<id>` |
| `jobs` | `slang-zokor` | 1/1 | 683,755 | 7,540 | 11 | $0.88 | 39,241 | 6.16 | 9.6 | `GET /jobs/<id>` |
| `jobs` | `ts-nest` | 1/1 | 460,506 | 11,659 | 10 | $0.63 | 6,668 | 16.64 | 170.0 | `GET /jobs/<id>` |
| `notes` | `go-fiber` | 1/1 | 343,637 | 7,450 | 8 | $0.50 | 107,777 | 1.24 | 14.8 | `GET /notes` |
| `notes` | `rust-axum` | 1/1 | 166,879 | 6,315 | 4 | $0.43 | 104,606 | 31.65 | 3.6 | `GET /notes` |
| `notes` | `slang-zokor` | 1/1 | 2,063,838 | 20,859 | 25 | $1.55 | 39,571 | 12.31 | 13.3 | `GET /notes` |
| `notes` | `ts-nest` | 1/1 | 881,971 | 16,559 | 18 | $0.87 | 5,424 | 19.92 | 170.4 | `GET /notes` |
| `ratelimit` | `go-fiber` | 1/1 | 293,383 | 6,425 | 7 | $0.46 | 96,423 | 1.79 | 15.4 | `GET /ping` |
| `ratelimit` | `rust-axum` | 1/1 | 288,248 | 6,345 | 7 | $0.46 | 115,350 | 5.61 | 3.5 | `GET /ping` |
| `ratelimit` | `slang-zokor` | 1/1 | 752,187 | **4,735** | 12 | $0.80 | 57,067 | 1.92 | 7.6 | `GET /ping` |
| `ratelimit` | `ts-nest` | 1/1 | 395,430 | 8,943 | 9 | $0.54 | 4,663 | 56.16 | 142.7 | `GET /ping` |
| `upload` | `go-fiber` | 1/1 | 253,385 | 8,346 | 6 | $0.49 | 104,220 | 1.93 | 12.3 | `GET /files/<id>` |
| `upload` | `rust-axum` | 1/1 | 210,761 | 6,040 | 5 | $0.43 | 131,102 | 0.47 | 6.4 | `GET /files/<id>` |
| `upload` | `slang-zokor` | 1/1 | 2,246,158 | 15,809 | 1\* | $1.47 | 46,154 | 14.41 | 11.4 | `GET /files/<id>` |
| `upload` | `ts-nest` | 1/1 | 385,678 | 10,550 | 8 | $0.64 | 5,604 | 17.71 | 172.2 | `GET /files/<id>` |

\* Note on `upload / slang-zokor`: Claude Code stopped and resumed around a slow zokor multipart test helper, so top-level `usage` (`101,601` tokens) and `num_turns` (`1`) only reflected the final post-wait response. The table above reports `modelUsage["claude-opus-5-5"]` full-session totals (`2,246,158` total tokens, `15,809` output tokens, `$1.47`) rather than the undercounted `usage` field.

### What this run shows (including where Slang loses)

1. **Where Slang wins — code compactness, binary size, and runtime efficiency vs. Node/NestJS:**
   - Across all 5 services, `slang-zokor` required only **705 non-test lines** (vs. **922** Go, **1,032** Rust, **1,705** TypeScript), compiled to an **867 KB** native binary (`auth`), used **9.6 MB median peak RSS** (less than Go+Fiber's **14.8 MB** and **17.7× less** than NestJS's **170.0 MB**), and served **46,154 req/s** (**8.5× faster** than NestJS's **5,424 req/s**).
   - Output tokens were already competitive or lowest whenever the agent didn't hit framework friction: **6,813** on `auth` (#1 of 4 stacks) and **4,735** on `ratelimit` (#1 of 4 stacks), with a median of **7,540** output tokens (below Go's 8,258 and TS's 11,659).
2. **Where Slang loses today — total input tokens and turns:**
   - `slang-zokor` cost **2.2×–3.6× more total tokens** (median **765k** vs. Rust **214k** and Go **343k**). Because frontier models are not pretrained on Slang or Zokor, the agent spends initial turns fetching `llms-small.txt` and querying `slangc doc`, and those fetched docs sit in conversation history across every subsequent `cache_read_input_tokens` turn.
   - `notes` (`25` turns, `2.06M` tokens) and `upload` (`2.25M` tokens) exposed concrete Slang/Zokor onboarding & ergonomic gaps (missing one-command scaffolding and a slow zokor multipart test helper on 1 MiB+ bodies). Addressing those in `slang` + `zokor` + `slanganalyser` is the next item in the roadmap.
3. **Where Go and Rust lead on raw HTTP microbenchmarks:**
   - `rust-axum` (`115.4k req/s`, `3.5 MB RSS`, `5` turns, `214k` total tokens) and `go-fiber` (`107.8k req/s`, `1.27 ms p99`) were 2.3×–2.5× faster in `wrk` loopback microbenchmarks than `slang-zokor` (`46.2k req/s`), and Rust+Axum led on total tokens because Claude already knows Axum idioms without fetching external docs.
