# Limitations

> What slang does not do, stated plainly.

## Known limitations

- Block scoping: a `let` inside `if`/`else`/`while`/`for` is not
  visible afterwards. Loop bindings (`for i in ...`) are scoped to
  the loop. Redeclaring a name in the same scope is an error;
  inner blocks may shadow. `guard let` still binds for the rest of
  its enclosing block.
- Strings are immutable; concatenation allocates. The collector
  reclaims unreachable strings automatically.
- Package globals require constant-literal initializers.
- Implicit returns only apply to the last statement of a function
  body; `if` and `{}` blocks are statements, not expressions yet.
- No closures. Functions are values (`fn(int) -> int`), but they
  capture nothing — a function value always names a top-level
  function, never an environment. `break`/`continue` work inside
  loops.
- Package-level lists are not supported yet (scalars and bytes are).
- Map keys are limited to integers, `str`, and `bool`.
- No data-race protection: `spawn` gives you real concurrency and
  per-task failure isolation, not an ownership/borrow checker.
  Mutating a shared struct/list/map from more than one task is on
  you, same as Go or Java — `mutex` is available for it, but nothing
  makes you reach for one.
- `select` has no timeout arm and no way to disable an arm. A closed
  channel's recv arm is ready forever (see Concurrency above), and
  there is no nil channel to switch it off with; for a deadline, feed
  a channel from a spawned timer task.
- `mutex` has no scope guard: without closures or `defer`, an early
  `return` between `mutex_lock` and `mutex_unlock` leaks the lock.
  Mutexes are also not recursive (locking one twice from the same
  task is a checked error, not a hang).
- TLS: no session resumption tuning. Handshake and send/recv park;
  `getaddrinfo` in `tls_dial` parks the task while a dedicated
  thread resolves. mTLS (`tls_ctx_require_client` /
  `tls_ctx_use_cert`) and SNI extra certs (`tls_ctx_add_sni`) are
  supported.
- JSON: no dynamic/unknown-shape decoding (every decode target is a
  concrete slang type known at compile time — see the `json` section
  above), and JSON object keys map to struct field names verbatim
  (no camelCase/snake_case conversion). `bytes` fields are base64
  strings (RFC 4648).
- `proc`: only `SIGTERM`/`SIGINT` are handled (there's no general
  signal-registration API); a signal that arrives in the narrow
  window before `main()` installs the handler gets the OS's default
  disposition (immediate termination) rather than graceful handling.
  `proc.wait_idle()` parks until `proc.active_tasks()` is zero.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
