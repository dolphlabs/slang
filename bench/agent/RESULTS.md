# Agent token benchmark: first run

**Headline: slang + zokor lost on every task.** It passed 4 of 5 tasks; go-fiber
and ts-nest each passed 5 of 5. On the four tasks slang passed, it used
**22.2× go-fiber's tokens and 9.9× ts-nest's** (summed: 31,121,942 vs 1,404,228
and 3,145,240). Per task that is 7.7–56.6× go-fiber and 8.0–12.4× ts-nest. The
median over all five tasks is 8,722,498 tokens for slang, 19.9× go-fiber's
439,048 and 11.7× ts-nest's 745,283. Every slang session but one hit the
80-turn cap. Most of the cost is the agent reading zokor's source files and
then re-sending them on every later request; see *Where slang's tokens went*.

This is **one run per cell**, not the three the method calls for (see
*Validity*), so no spread is measured.

## Run

| | |
|---|---|
| Date | 2026-09-30 20:35:48 UTC – 2026-10-01 01:19:14 UTC (results dir `20260930T203548Z`) |
| Machine | Shared Debian 13 (trixie) box, kernel 6.12.94+, 8 × Intel Xeon Processor (model not reported), 15 GiB RAM. **Not** Ubuntu 24.04, and **not in a container or VM**: no docker or podman was available. Other agents used the same machine during the run. |
| slangc | 0.2.1, built from dolphlabs/slang `dev` at `7c98a64a657d96241c1f4effdbda3776f8467050`. `bench/agent/` is identical at that commit and at this branch's base. |
| zokor | `tag v0.1.0` → commit `e6238681aa2a5825a5465c6bf165166ab3b01f42`; lock hash `sha256:ff7d485858341e53b711ffce42add7fa71ca6842b578428434abaf6271623164` |
| Go / Fiber | go1.27.1 linux/amd64; Fiber is whatever version each agent chose (see each `go.mod`) |
| Node / Nest | node v22.23.3, npm 10.9.9, @nestjs/cli 12.0.8 |
| Agent | opencode-ai 1.18.33, driven by a wrapper (below) |
| Model | `openrouter/poolside/laguna-s-2.1:free` through OpenRouter's free tier. The provider reported every cost as $0, so the `cost` column shows `-`. |
| C compiler | gcc (Debian 14.2.0-19) 14.2.0 |

```sh
AGENT_CMD='env AGENT_MODEL=openrouter/poolside/laguna-s-2.1:free AGENT_MAX_TURNS=80 /workspace/slang-bench/agent/agent-wrap'
python3 -u bench/agent/run.py run --runs 3      # stopped after round 1, see below
```

`agent-wrap` is a local script, not in this repo. It does the following:

- Runs `opencode run` with that model, `steps: 80`, every tool allowed except
  `task` and `question` (which are denied).
- Gives each run a fresh opencode home inside the run dir, with
  `share: disabled` and `autoupdate: false`.
- Sets `GIT_CEILING_DIRECTORIES` and a hard timeout of 3,480 s.
- Prints the `usage` / `num_turns` / `total_cost_usd` report that `run.py` expects.

Input tokens include cache reads and writes, as the README specifies. A
"turn" is one model request (an opencode step). The API key was passed in the
environment and appears in no artifact.

**Build workaround.** Plain `make` of slang fails under GCC 14:

```
src/codegen/generics.c:284:14: error: assignment to ‘struct StructTmpl *’ from incompatible pointer type ‘StructTmpl *’ [-Wincompatible-pointer-types]
src/codegen/generics.c:384:22: error: initialization of ‘StructTmpl *’ from incompatible pointer type ‘struct StructTmpl *’ [-Wincompatible-pointer-types]
make: *** [Makefile:66: slangc] Error 1
```

It was built with `make CC="cc -Wno-error=incompatible-pointer-types"` and
`sudo make install`, with no source edits.

**Smoke run (excluded).** `results/20260930T202839Z` (notes / slang-zokor,
1 run) ended `FAIL no start.sh tokens=142281 turns=10`. The upstream provider
returned 429 and the session ended after opencode's retries. It is not part
of these results.

**Stopped after round 1.** The user decided to stop the matrix after the first
of three rounds. The runner was stopped right after the 15th result. One
round-2 session (`auth/go-fiber/2`) had been created but was blocked before
it made any model call. It is an incomplete session excluded by that
decision, not a failure, and it is not in `results.jsonl`.

## Results

`python3 bench/agent/run.py summary bench/agent/results/20260930T203548Z`:

```
task       stack         runs      pass  tokens(med)  out(med)  turns     cost
auth       go-fiber         1    1/1          169660      6598     15        -
auth       slang-zokor      1    1/1         8515953    103195     80        -
auth       ts-nest          1    1/1          745283     18865     35        -
jobs       go-fiber         1    1/1          439048     14082     23        -
jobs       slang-zokor      1    1/1         8722498     61194     69        -
jobs       ts-nest          1    1/1         1061566     27680     41        -
notes      go-fiber         1    1/1          158731      8073     13        -
notes      slang-zokor      1    1/1         8987185     69855     80        -
notes      ts-nest          1    1/1          725178     30396     26        -
ratelimit  go-fiber         1    1/1          636789     18179     36        -
ratelimit  slang-zokor      1    1/1         4896306     59449     80        -
ratelimit  ts-nest          1    1/1          613213     17262     26        -
upload     go-fiber         1    1/1         2499187     41533     61        -
upload     slang-zokor      1    0/1        10291086    113235     82        -
upload     ts-nest          1    1/1         2297517     35516     80        -
```

Per request. "First write" is the first turn that wrote service code.

| task | stack | turns | input | output | input/turn | median ctx | max ctx | first write |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| auth | go-fiber | 15 | 163,062 | 6,598 | 10,870 | 10,995 | 15,730 | 5 |
| auth | slang-zokor | 80 | 8,412,758 | 103,195 | 105,159 | 145,835 | 189,920 | 43 |
| auth | ts-nest | 35 | 726,418 | 18,865 | 20,754 | 22,481 | 32,524 | 10 |
| jobs | go-fiber | 23 | 424,966 | 14,082 | 18,476 | 19,675 | 24,507 | 6 |
| jobs | slang-zokor | 69 | 8,661,304 | 61,194 | 125,526 | 145,231 | 169,138 | 33 |
| jobs | ts-nest | 41 | 1,033,886 | 27,680 | 25,216 | 26,004 | 46,433 | 11 |
| notes | go-fiber | 13 | 150,658 | 8,073 | 11,589 | 13,448 | 16,718 | 5 |
| notes | slang-zokor | 80 | 8,917,330 | 69,855 | 111,466 | 118,531 | 172,908 | 57 |
| notes | ts-nest | 26 | 694,782 | 30,396 | 26,722 | 30,811 | 47,458 | 10 |
| ratelimit | go-fiber | 36 | 618,610 | 18,179 | 17,183 | 16,434 | 30,604 | 5 |
| ratelimit | slang-zokor | 80 | 4,836,857 | 59,449 | 60,460 | 59,711 | 111,223 | 14 |
| ratelimit | ts-nest | 26 | 595,951 | 17,262 | 22,921 | 25,094 | 32,709 | 4 |
| upload | go-fiber | 61 | 2,457,654 | 41,533 | 40,289 | 42,604 | 67,633 | 39 |
| upload | slang-zokor | 82 | 10,177,851 | 113,235 | 124,120 | 121,004 | 230,630 | 76 |
| upload | ts-nest | 80 | 2,262,001 | 35,516 | 28,275 | 25,623 | 53,228 | 4 |

**Per-turn context is the cost.**

- slang's median input per turn was 111,466 tokens, against 17,183 for
  go-fiber and 25,216 for ts-nest (6.5× and 4.4×).
- Its median turn count was 80, against 23 and 35 (3.5× and 2.3×).
- The product of those two ratios is the ≈20× and ≈12× gap.
- Output per turn is about the same on every stack (medians: slang 887,
  go-fiber 612, ts-nest 664 tokens), so slang's agent didn't generate much
  more. It kept re-sending more.
- slang's context peaked at 111k–231k tokens. upload's 230,630 triggered
  opencode's auto-compaction at requests 81–82.
- The fixed part (system prompt + task prompt, about 6.9k tokens re-sent
  every request) is only 6.6% of slang's input.

## Per-task notes

- **auth.** Every stack passed.
  - slang: 80 turns, first code at turn 43. Steps 8–17 went on retyping the
    64-hex `~/.cache/slang/pkg/zokor/sha256:…` path wrong; the model dropped
    characters and blamed the colon. It then printed zokor's errors.sl,
    router.sl and json.sl in full.
  - Then three compile rounds on a trailing comma in a struct literal.
  - Then about 20 turns of testing, including opencode bash-tool timeouts
    (30 s, 120 s, 10 s) from starting the server in the foreground.
  - go-fiber was done in 15 turns.
- **jobs.** Every stack passed.
  - slang: 69 turns, first code at turn 33, after reading zokor source and
    the slang runtime's scheduler and mutex C code.
  - Then 4 compile fixes: `result` as a field name, a trailing comma, a
    stray `)`.
  - It also read `auth/slang-zokor/1/work/main.sl` (see *Validity*).
- **notes.** Every stack passed.
  - slang: 80 turns, first code at turn 57. It ran probe programs to learn
    what `to_int` returns and how `??` behaves.
  - Turns 62–77 chased a return-type error that slangc reported in zokor's
    `router.sl:81` (and :6, :5). The real bug was the agent's own
    `fn note_id(...) -> opt[int] { return to_int(..) }`.
  - It fixed this at turn 78 and the cap ended the session at turn 80.
- **ratelimit.** Every stack passed.
  - slang: 80 turns. It wrote code at turn 14, then spent about 30 turns
    reading headers, `Retry-After` and `time.mono` code.
  - It learned that a top-level `let` isn't visible inside functions
    (4 undefined-variable errors) and probed `??` on non-optionals.
  - It looked at other runs' work dirs for test layout.
- **upload.** slang-zokor **failed**; go-fiber passed in 61 turns and
  ts-nest passed in 80 (the cap).
- **upload / slang-zokor failure** (`FAIL no start.sh`):
  - The agent read zokor and slang runtime source for 75 turns: router.sl,
    serve.sl, internal/multipart, errors.sl, upload.sl, sl_core.c, sl_net.c,
    sl_proc.c, stdlib/http.
  - It was looking for request-size limits, the arena, the bind address,
    the mutex type and how SIGTERM wakes the server.
  - It wrote `main.sl` at turn 76, compiled at 77, tested at 79 and hit the
    80-step cap before writing `start.sh`. Turns 81–82 are opencode's
    auto-compaction.
  - Cause: the turn budget ran out on API discovery. No compile error or
    contract bug was involved.

## Where slang's tokens went

Method: a tool result of *s* tokens produced at request *i* is paid again by
every later request. Each result's size is taken as chars/4 times the number
of later requests, scaled so the run's total matches the provider-reported
input minus the fixed prompt. This is an attribution, not a measurement of
each item.

| share of slang input (all 5 runs, 41.0M tokens) | % |
|---|---:|
| reading zokor / slang source (cat/sed/read of `.sl` and runtime `.c` files) | 65.8 |
| `slangc doc zokor` pages | 9.8 |
| the slang + zokor guides (llms-small) | 9.0 |
| zokor README fetched from GitHub | 4.2 |
| fixed system + task prompt | 6.6 (included in the rows above, not added to them) |
| everything else (bash, test/debug, writes, compiles, todo) | ≈4.6 |

Per run, source reads were:

| run | source reads | other notable shares |
|---|---:|---|
| auth | 62% | slangc doc 16%, guides 10% |
| jobs | 81% | |
| notes | 66% | README 9%, slangc doc 8%, guides 8% |
| ratelimit | 36% | slangc doc 23%, guides 15% |
| upload | 70% | README 9%, slangc doc 8%, guides 7% |

About 85–90% of the source reads were zokor itself (errors.sl, router.sl,
json.sl at about 51–61k characters each, serve.sl, internal/multipart). The
rest were the slang repo's stdlib, tests and runtime C.

**Why three runs (four, counting upload) hit the cap.** Exploration used the
turns. The median first code write was turn 43 for slang, against 5 for
go-fiber and 10 for ts-nest. After that came compile loops and test loops.

### Distinct slangc errors

First line as printed, with how often each appeared:

| error | count | where | cause |
|---|---:|---|---|
| `main.sl:87: error: expected a field name but found '}'` | 4 | auth 3, jobs 1 | trailing comma in a struct literal |
| `main.sl:10: error: expected a field name but found 'result'` | 2 | jobs | `result` is a reserved word |
| `main.sl:98: error: expected an expression but found ')'` | 1 | jobs | stray `)` |
| `…/zokor/…/src/router.sl:81: error: return type mismatch: cannot return result[int,str] where opt[int] expected` (also at router.sl:6 and :5) | 5 | notes | the user's function; **reported in zokor's file** |
| `tint.sl:1: error: null-coalescing fallback type mismatch: cannot use opt[int] where int expected` | 3 | notes | probing what `to_int` returns |
| `main.sl:46: error: type 'builder.Str' has no method 'write_str'` | 2 | notes | wrong method name (`write`) |
| `listtest.sl:14: error: undefined variable 'json'` | 1 | notes | missing `import "json"` |
| `main.sl:3: error: cannot convert opt/result to str; unwrap first` | 1 | notes | |
| `main.sl:6: error: guard's else must leave the scope…` | 1 | notes | |
| `min1.sl:3: error: redefinition of struct 'App' in package 'work'` | 1 | notes | a scratch file in the same dir is the same package |
| `main.sl:34: error: undefined variable 'WINDOW_NS'` / `vis.sl:3: error: undefined variable 'LIMIT'` | 4 | ratelimit | a top-level `let` is not visible inside functions |
| `patterntest.sl:15: error: null-coalescing requires an opt or result value on the left (got int)` | 1 | ratelimit | |
| `vistest.sl:1: error: redeclaration of 'LIMIT' in the same scope` | 1 | ratelimit | |
| `slang runtime error: assertion failed at main:25` | 1 | ratelimit | a bug in the agent's own probe test |

upload hit no compile errors. It barely compiled.

### Code written by hand

- **All 5 runs:** the same `render_error(v: zokor.ErrorView)`, installed with
  `zokor.set_renderer`, to produce exactly `{"error":{"code","message"}}`.
  zokor's default envelope also carries `status` and `request_id`. The API
  exists, but the zokor guide mentions neither `set_renderer` nor
  `ErrorView`, so every run found it by reading `errors.sl`.
- **ratelimit:** a fixed-window limiter (zokor has no rate-limit
  middleware), using `time.mono`, with `Retry-After` set through
  `zokor.with_header` (not in the guide).
- **jobs:** a background worker from `spawn`, `time.sleep` and a mutex
  (zokor has no job or worker primitive).
- **auth:** a token store using `crypto.rand` with hex encoding and maps
  behind a mutex (zokor has `bearer()` but no token or session store).
- **notes:** `fields_message` (field errors to one message string),
  `parse_note` and `index_of`.
- **upload:** the `FormError` → error-code mapping around
  `zokor.file(form, "file")`.

### zokor gap table, updated from the runs

The zokor API has most of what the tasks need. The one-page guide doesn't
show it, so agents went to the source.

| need (task) | in zokor's API (`slangc doc zokor`) | in zokor llms-small | what the runs did |
|---|---|---|---|
| exact error envelope (all) | `set_renderer`, `ErrorView{code,message,status,request_id,fields}` | 0 mentions | all 5 read errors.sl, then hand-wrote a renderer |
| response headers, e.g. `Retry-After` (ratelimit) | `with_header` | 0 | read router.sl and serve.sl |
| request headers (auth, ratelimit) | `header` (10 mentions in the doc) | 0 | read source |
| multipart upload, size limits, safe names (upload) | `file`, `Upload`, `UploadRules`, `FormError`, `multipart.Limits`, `ServerConfig.max_request_bytes` | `file`/`upload` once each, no example | 75 turns of source reads, then the session failed |
| server limits, bind address, shutdown (upload, jobs) | `ServerConfig{…timeouts, max_request_bytes…}` | 0 | read serve.sl and runtime sl_net.c |
| shared state with a mutex (auth, jobs, ratelimit) | none (it's slang: `make_mutex`) | 0 | read runtime C to find the type name for a struct field |
| background worker (jobs) | none (slang `spawn`) | spawn 2 | hand-written |
| rate limiting (ratelimit) | none | 0 | hand-written |
| builtin signatures (`to_int` → `result[int,str]`) | not in `slangc doc` | slang guide: 1 example, no signature | notes probes plus a 16-turn loop |

## Secondary metric: size of each passing solution

Counted: service code (`.sl` / `.go` / `.ts`, plus `start.sh`), as tokens
under tiktoken `o200k_base` (not the model's own tokenizer).

- Excluded: lockfiles (`slang.lock`, `go.sum`, `package-lock.json`,
  `pnpm-lock.yaml`), `node_modules`, `dist`, `*.tsbuildinfo` and binaries.
- "Config" covers manifests and scaffold config (`go.mod`, `slang.project`,
  `package.json`, tsconfig, nest-cli, prettier, README).
- Tests are counted separately.
- upload/slang-zokor failed, so it isn't listed.

| task | go-fiber code | slang-zokor code | ts-nest code | config (go / slang / ts) |
|---|---|---|---|---|
| auth | 173 lines / 1,106 tok | 106 / 831 | 243 / 1,630 (12 files) | 231 / 36 / 2,755 tok |
| jobs | 153 / 848 | 143 / 1,037 | 159 / 991 (9 files; +51 lines of tests) | 227 / 35 / 2,977 |
| notes | 216 / 1,381 | 192 / 1,641 | 240 / 1,468 (7 files) | 230 / 69 / 2,755 |
| ratelimit | 97 / 506 | 86 / 669 | 92 / 553 (5 files) | 227 / 37 / 282 |

slang's final programs are short: fewest lines in all four tasks, though not
the fewest tokens in three of them. The cost was not in writing them.

## Validity

- **One run per cell.** The method asks for three, interleaved, with medians
  and spread. The user stopped after round 1, so there is no spread, and no
  difference here can be tested against run-to-run noise. Most of the gaps
  are an order of magnitude (slang against go-fiber: 7.7–56.6× per task),
  which is unlikely to be noise. The go-fiber vs ts-nest ordering is not
  settled.
- **Cross-run reads.**
  - jobs/slang-zokor read `auth/slang-zokor/1/work/main.sl` (step 5) and its
    `slang.project` (step 21), so it started with a working zokor program.
  - ratelimit/slang-zokor read auth's `slang.project` and `slang.lock` and
    listed its work dir (steps 8–10). At step 58 it listed the jobs, notes
    and auth work dirs and grepped `*/slang-zokor/1/work/` for tests.
  - No go-fiber or ts-nest run read another run's dir.
- **Reads outside the work dir.**
  - Every slang run read the slang checkout itself (stdlib, tests, runtime C,
    `src/codegen`), and upload ran the checkout's `./slangc`.
  - jobs and ratelimit also read a zokor clone and three scratch dirs left
    on the box from setup.
  - No transcript read or listed `accept.py`, `reference/`, `tasks/` or
    `fake_agent.py`. The only `../..` hits are an import path in
    auth/ts-nest and `../../etc/passwd` test filenames in the upload runs.
- **No container.** The run used a shared box. Results live inside the slang
  checkout, which is what made the reads above possible.
- **Free model.** The run used a free model with an 80-turn cap. A stronger
  model may explore less. The cap hit slang hardest (4 of 5 sessions) and
  ts-nest once (upload).
- **Excluded:** the stopped round-2 session `auth/go-fiber/2` and the smoke
  run.

## Fixes, ranked by estimated savings

The estimates come from the attribution above and a re-send model (removing
a result saves its size times the number of later requests; removing a turn
also saves its context and output). They are estimates, not measurements.

1. **Put the missing recipes and an API index in zokor's llms-small** (or
   ship a complete `llms-full`): custom envelope via
   `set_renderer`/`ErrorView`, request and response headers (`header`,
   `with_header`), multipart (`file`, `UploadRules`, `FormError`, limits),
   `ServerConfig` fields, bind address and shutdown, and shared state with a
   mutex plus a `spawn` worker.
   - Evidence: 65.8% of slang input was source reads, aimed at exactly these
     names, all with 0 mentions in the guide.
   - Fixes 1 and 2 together: about **80% of slang's tokens** in the model.
     Removing the source and doc reads takes 41.4M to about 8.2M, even after
     adding an 8k-token API index to every request.
2. **Make `slangc doc` searchable and complete**: a symbol query like
   `slangc doc zokor.set_renderer`, builtins included, compact output.
   - Evidence: 9.8% of input was paging the 27 kB `slangc doc zokor` dump
     with `sed -n`. When a name wasn't there, agents went back to `cat`.
3. **Report errors in the user's file.** The `opt[int]` / `to_int` mismatch
   was attributed to zokor's `router.sl:81`.
   - Evidence: notes turns 62–77, about 16 turns at roughly 150–170k context.
   - Savings: about 2.48M tokens, 28% of that run.
4. **Add a builtin and gotcha table to slang's llms-small**: `to_int` →
   `result[int,str]` and the other conversion builtins; `??` on opt vs
   result; a top-level `let` isn't visible in functions; no trailing commas;
   reserved words (`result`); every `.sl` file in a directory is one package.
   - Evidence: 4 trailing-comma errors, 2 `result` errors, 4 top-level-let
     errors, 3+1 `??` errors, the `App` redefinition, notes' to_int probes
     (turns 34–40) and ratelimit's probes (turns 49–50, 57–59, 61–65).
   - With fixes 3 and 5: a further ≈5 points (about 8.2M → 6.2M in the model).
5. **A stable, printable package path** (`slangc pkg path zokor`, or a
   `./.slang/pkg/zokor` link). Evidence: auth's 10-turn detour on the 64-hex
   `sha256:` directory (about 0.58M tokens, 7% of that run), and notes cloning
   zokor into `/tmp` to read it.
6. **Diagnostic hints**: accept trailing commas, or say "trailing comma not
   allowed"; say "`result` is a reserved word"; on an undefined name that
   matches a top-level `let`, say functions can't see it. About 1–2%.
7. **A "run the server while testing" recipe** in the guide (background it
   with a log file and pid, wait for the port, kill it) and a fast dev build
   without LTO. Evidence: auth's bash-tool timeouts and roughly 10 s per LTO
   build. About 1–3%; it affects every stack a little.
8. **Benchmark hygiene** (validity, not tokens): keep results outside the
   checkout, run each session in a fresh container, and keep setup scratch
   dirs out of reach.

## Artifacts

The transcripts, prompts, agent reports, acceptance output and final work
dirs are in a tarball linked from the PR. It excludes `node_modules`,
`dist`, compiled binaries, and opencode's package cache, database and
snapshots. It was scanned for credentials first; nothing was found. The
results dir itself is gitignored.
