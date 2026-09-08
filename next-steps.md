# next steps

Track progress top to bottom; tick items as they land. This file is the
active queue after the HTTP perf chase paused (slang is in Go's RPS/p99
range; RSS still loses — revisit later, not now).

## HTTP perf (paused)

- [x] Spawn-inline args (`sl_task_submit_copy`, no heap alloc per accept)
- [x] Profile VM under wrk c=50 (safepoint/checkin on serve path, not freelist)
- [x] Revert MPSC task freelist (no win; profile said ~0.2%)
- [x] Revert Linux TLS-inline of `sl_rt_cur` (segfault: `sl_ctx_switch` onto rsi=0)
- [x] Hoist for-in safepoint to once per loop (roots iterable alias)
- [ ] Phase E win vs Go on **both** p99 and RSS (deferred)

## Error visibility + log (current focus)

Errors are easy to **handle** (`guard let`, `??`, `fault`) and hard to
**see** (else branch throws away `E`, no levels, no context).

- [x] Pick error-access shape: `guard let x = r else let e = err_of(r) { ... }`
- [x] Implement chosen shape in parser + codegen + tests
- [x] `to_str(fault)` via `sl_str_from_fault`
- [x] `log` package: debug/info/warn/error to stderr with timestamp
- [x] `log` accepts `str` or `fault`, `fault` concatenates with `+`
- [x] Demo: HTTP/TLS handlers log parse/I/O failures via `err_of`

## Language features (after log)

- [ ] `crypto` — hash (SHA-256), HMAC, CSPRNG (TLS exists; services need these)
- [ ] SQL — driver + `result`/connection errors wired through same visibility story
- [ ] `regex` — compile/match on `str` or `bytes`
- [ ] HTTP/2 — multiplexing, ALPN (builds on `net` + TLS)
- [ ] Second `os` package — env beyond `proc`, argv, cwd, file metadata (avoid duplicating `fs`)

## Error model gaps (fold into log slice or follow immediately after)

- [x] `guard let` else binds the error value for `result[T, E]` via `err_of`
- [ ] Consistent story for `opt` none vs `result` err vs `fault` (when to use which in stdlib)
- [ ] Richer `fault` context (errno, peer, op) without breaking the closed enum
- [ ] Panic message quality (spawn join already surfaces string; no stack yet)

## Notes

- Do not change `bench/http/main.sl` for perf experiments.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
