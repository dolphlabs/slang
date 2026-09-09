# next steps

Track progress top to bottom; tick items as they land. The HTTP perf
chase is won on the raw axis (Phase E vs Go on p99 **and** RSS, PR #59
records the numbers); the ruler stays frozen and Round 2 follow-ups
live in `optimisation.md`. Error model gaps are done. Current focus is
the language features, starting with SQL.

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

## Language features (crypto done, SQL is current focus)

- [x] `crypto` — hash (SHA-256), HMAC, CSPRNG (PR #68: native package over OpenSSL; `sha256`/`hmac_sha256` return `bytes`, `rand` returns `result[bytes, str]`; `-lcrypto` gated on `want_crypto`)
- [ ] SQL — driver + `result`/connection errors wired through same visibility story
- [ ] `regex` — compile/match on `str` or `bytes`
- [ ] HTTP/2 — multiplexing, ALPN (builds on `net` + TLS)
- [ ] Second `os` package — env beyond `proc`, argv, cwd, file metadata (avoid duplicating `fs`)

## Error model gaps (done)

- [x] `opt` none vs `result` err vs `fault`: documented rule + stdlib audit (PR #63: README rule — absent data is `opt`, bad data is `result[_, str]`, bad world is `result[_, fault]`; `http.parse` threads `err_of` context, `http.read` returns `result[Incoming, str]` with descriptive errors)
- [x] Richer `fault` context without breaking the closed enum (PR #64: `op` + `code` on `sl_fault`; `==`/`fault_kind` kind-only; `fault_op`/`fault_code` accessors; net tags send/recv/accept/dial/connect with op + errno)
- [x] Panic message quality (PR #65: `sl_rt_error_at` threads `pkg.func:line` through div-by-zero, `err_of`-on-ok, map-missing-key, and list/bytes/wire bounds; `join_wait` surfaces the located string)

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
