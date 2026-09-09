# next steps

Track progress top to bottom; tick items as they land. The HTTP perf
chase is won on the raw axis (Phase E vs Go on p99 **and** RSS, PR #59
records the numbers); the ruler stays frozen and Round 2 follow-ups
live in `optimisation.md`. Current focus is the error model gaps.

## HTTP perf (won on raw axis, ruler frozen)

- [x] Spawn-inline args (`sl_task_submit_copy`, no heap alloc per accept)
- [x] Profile VM under wrk c=50 (safepoint/checkin on serve path, not freelist)
- [x] Revert MPSC task freelist (no win; profile said ~0.2%)
- [x] Revert Linux TLS-inline of `sl_rt_cur` (segfault: `sl_ctx_switch` onto rsi=0)
- [x] Hoist for-in safepoint to once per loop (roots iterable alias)
- [x] Raw-axis Phase E vs Go on **both** p99 and RSS (`optimisation.md`, PR #59)

## Error visibility + log (done)

Errors are easy to **handle** (`guard let`, `??`, `fault`) and hard to
**see** (else branch throws away `E`, no levels, no context).

- [x] Pick error-access shape: `guard let x = r else let e = err_of(r) { ... }`
- [x] Implement chosen shape in parser + codegen + tests
- [x] `to_str(fault)` via `sl_str_from_fault`
- [x] `log` package: debug/info/warn/error to stderr with timestamp
- [x] `log` accepts `str` or `fault`, `fault` concatenates with `+`
- [x] Demo: HTTP/TLS handlers log parse/I/O failures via `err_of`

## Language features (after error model)

- [ ] `crypto` — hash (SHA-256), HMAC, CSPRNG (TLS exists; services need these)
- [ ] SQL — driver + `result`/connection errors wired through same visibility story
- [ ] `regex` — compile/match on `str` or `bytes`
- [ ] HTTP/2 — multiplexing, ALPN (builds on `net` + TLS)
- [ ] Second `os` package — env beyond `proc`, argv, cwd, file metadata (avoid duplicating `fs`)

## Error model gaps (current focus)

- [x] `guard let` else binds the error value for `result[T, E]` via `err_of`
- [ ] `opt` none vs `result` err vs `fault`: documented rule + stdlib audit (`http.parse` returns `result[_, str]` while `http.read` returns `result[_, fault]`, and `read` collapses 7 distinct failures to `fault_io()`)
- [ ] Richer `fault` context (errno, peer, op) without breaking the closed enum (`==`, `fault_kind()` keep working; `log.warn` printing bare `io` is the symptom)
- [ ] Panic message quality (`sl_rt_error` prints msg + two ints, no task/function/line; join surfaces the string, no stack yet)

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
