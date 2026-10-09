# PRD: Faster `json.decode`

Status: approved for implementation, pending Linux profile evidence

## Problem

The REST quote and mix workloads still spend about 0.6-0.7 ms of each minor
collection waiting for a worker to reach a safepoint. The late worker is
usually completing a `json.decode` of an approximately 110 KB, 2,000-item
quote request. Async GC kicks do not shorten that interval: measurements in
`fix-gc.md` recorded about 11 refused kicks per collection while the decoder
was inside allocator or libc preemption brackets. Earlier decoder polls also
made partially built results visible to the collector and promoted them.

A decoder speedup therefore has two benefits: it reduces CPU per JSON request
and shortens the collector's time-to-safepoint by the same amount without
changing the collector or exposing incomplete values.

## Product and technical context

slang is a statically typed backend language that emits C. Its programs run
on M:N green threads with 8 KB starting stacks and a precise, generational,
stop-the-world collector. JSON is a native generic package whose codecs are
monomorphized from the requested slang type.

The current decode path is split across:

- `src/codegen/pkg_json/dispatch.c`, which emits direct typed `sl_jdf_*`
  decoders and the tree-decoder fallback used to preserve detailed errors;
- `runtime/sl_json.c`, which provides the bounds-checked parser primitives,
  string/number parsing, value skipping, tree parser, and error helpers;
- `bench/gc/decode/main.sl`, which repeatedly decodes the production-shaped
  quote body while keeping and walking each result as the API handler does;
- `tests/json*` and the JSON allocation budget in `tests/run_tests.sh`, which
  pin semantics, malformed-input handling, exact integers, UTF-8, deep
  nesting, GC correctness, and allocation counts.

The direct path already decodes integers in one pass, tries the statically
expected struct key first, reads unescaped keys in place, fills plain structs
inline, and falls back to the generic tree path when it cannot preserve the
full decode contract directly. Composite values are decoded before an object
that owns them is allocated so no safepoint can leave an initialized old
holder pointing at an unbarriered young value. Lists and maps are filled by
barriered container operations.

## Goal

Reduce the CPU time and instruction count of valid, production-shaped typed
JSON decoding, with a corresponding improvement in quote-request throughput
or latency, while preserving every existing language, error, security, GC,
and allocation contract.

The implementation must follow a Linux profile of current `dev`. A suspected
hot path is not sufficient evidence.

## Scope

1. Profile the current 2,000-item quote decode on Linux and attribute samples
   and instructions to generated decoders, runtime parsing, allocation/GC,
   and libc.
2. Make the smallest production-quality change supported by that profile.
3. Verify semantic parity, malformed-input safety, allocation budgets, GC
   correctness, generated-C warnings, and the complete test suite.
4. Measure the old and new revisions on the same cloud host in ABBA order.
5. Record the result and any remaining decoder costs in `todo.md`,
   `next-steps.md`, and `fix-gc.md` where their existing plans require it.

## Non-goals

- No language syntax, public API, or on-disk format changes.
- No dynamic JSON value API or change to typed decoding.
- No decoder safepoints, polling, kick handling, or GC scheduling changes.
- No visibility of partially initialized decode results to the collector.
- No speculative allocator, collector, scheduler, HTTP, or database work.
- No relaxation of validation, bounds, depth, error, or allocation limits.
- No edits to `bench/http/main.sl`.

## Required behaviour and safety invariants

The optimized decoder must preserve:

- the exact accepted and rejected JSON grammar;
- exact integer decoding, including exponent/fraction forms that represent a
  whole number and overflow checks for every integer type;
- floating-point conversion behaviour;
- a maximum nesting depth of 512 and bounded C-stack use;
- malformed-input errors instead of crashes or ambiguous recovery;
- existing field-path diagnostics through the tree fallback;
- missing optional fields, required fields, unknown keys, repeated keys,
  escaped keys, Unicode, bytes/base64, maps, lists, enums, recursive types,
  plain structs, and GC structs;
- hostile-input bounds checks and size caps;
- write barriers for every heap pointer store;
- no safepoint between allocation and unbarriered initialization;
- task-code TLS access only through the required accessors;
- preemption brackets around libc calls that can allocate or lock;
- generated C that is warning-free with GCC and Clang;
- current JSON allocation budgets. A budget may not be raised to hide a
  regression.

## Measurement plan

All performance results must come from the configured Linux cloud benchmark
environment. Record the commit, CPU, kernel, compiler, perf/callgrind versions,
worker count, input size, iteration count, and raw samples.

### Baseline profile

Generate the inputs when absent:

```sh
python3 bench/suite/lib/gen_quote.py DIR 8 2000
```

Build `bench/gc/decode` from unmodified `dev`, then profile the 2,000-item
body with one task and enough iterations for stable samples:

```sh
QUOTE=DIR/quote_0.json TASKS=1 ITERS=2000 perf record -g ./decode
```

Report inclusive and self cost for generated `sl_jdf_*` functions, runtime
`sl_jd_*` primitives, allocation/GC, and libc. Capture a callgrind instruction
baseline as the stable work metric.

### Before/after

Run old/new/new/old over several rounds on the same host and report every raw
value plus medians. A change smaller than the run-to-run spread is noise.

Measure:

- single-task decode probe;
- four-worker/four-task decode probe when the profile or change can affect
  concurrent decoding;
- `/api/quote` under `bench/latgen`, including throughput, CPU per request,
  p50/p99/p99.9, socket/non-2xx errors, and peak RSS;
- Go on the same server benchmark session before making any server-speed
  claim;
- callgrind instructions before and after.

Every server run must use the benchmark port guard and verify the process that
owns the port before load begins. A leftover server invalidates the run.

## Verification plan

Run the focused JSON tests, including `json`, `json_parity`, `json_utf8`,
`json_int_exact`, `json_key_order`, `json_deep_nesting`,
`json_plain_struct_decode`, `json_value_structs`, and `json_decode_budget`.

Run the relevant JSON and container cases with:

```sh
SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16
```

The verifier must report `missed=0`. Run the allocation-budget section without
raising any threshold. Finish with exactly one `make test` and report its test
count and generated-C warning sweep.

This is expected to be a behaviour-preserving performance change. Do not
invent a behavioural regression test that already passes on old code. If the
profiled optimization fixes a real semantic bug, add a focused test and show
it failing on old code and passing on the new code. Otherwise, use existing
parity tests plus an appropriate structural or performance guard and state why
the failing-before criterion does not apply to unchanged behaviour.

## Acceptance criteria

The change may land only when all of the following hold:

- Linux profiling identifies the optimized cost as material on current `dev`.
- The ABBA decode median improves beyond the observed spread, with no material
  regression in the four-worker case.
- Callgrind instruction count is neutral or lower and agrees with the proposed
  explanation of the win.
- The quote API shows a measurable improvement or is explicitly reported as
  neutral; any speed claim includes p99, peak RSS, and Go from the same host.
- JSON allocation counts do not increase.
- Focused tests, GC verification, allocation budgets, and `make test` pass.
- No user-visible JSON behaviour, error quality, or security boundary regresses.
- Planning documents record measured findings, the change, and remaining work.

If the profile does not support a safe improvement, the deliverable is this
PRD plus the profile and an investigation note. Speculative code must not land.

## Delivery

Use branch `perf/json-decode-speed`, based directly on current `dev`, and open
the pull request against `dev`. Use signed-off conventional commits with a
subject no longer than 72 characters. Stage files by name. If user-facing docs
change, run `make docs` and commit generated `docs/` separately. The final PR
description must use `What changed`, `Why`, and `Notes for reviewer`, include
raw before/after evidence, and state every skipped or failed check.
