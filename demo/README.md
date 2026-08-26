# Slang Arcade

A demo server exercising essentially every feature slang has, in one
runnable application: a dice game with a leaderboard, a guestbook
wall, and a live "server pulse" dashboard, served over both plain
HTTP and TLS, with a graceful-shutdown story that actually drains
in-flight connections instead of dropping them.

## Run it

```sh
cd demo
./run.sh
```

Then open **http://localhost:8090/**. `run.sh` builds `lib.c` (the
demo's tiny C fixture) into a static archive, generates a self-signed
cert on first run (needs `openssl` on your `PATH`), and starts the
server. Stop it with Ctrl-C — you'll see it wait for any in-flight
request to finish before it actually exits.

`PORT`/`TLS_PORT` env vars override the defaults (8090/8091):

```sh
PORT=9000 TLS_PORT=9001 ./run.sh
```

If you'd rather run it directly (`../slangc main.sl --run`), that
works too, but skips the cert generation — the server falls back to
plain HTTP only in that case and says so on startup.

## What's on the page

- **Live Server Pulse** — uptime, request count, currently-running
  `spawn`ed tasks, message/player counts, PID. Polled every 1.5s.
- **Dice Duel** — type a name, roll two dice (via the C library),
  see a live leaderboard of best rolls per player.
- **Guestbook Wall** — post a name, a message, and an optional mood;
  see the wall update immediately.

None of the frontend is a static file — there's no file-I/O builtin
exposed to slang programs, so `content/` holds slang functions that
return the HTML/CSS/JS as strings, the same way the compiler embeds
its own C runtime.

## What it demonstrates, and where

| Feature | Where |
|---|---|
| `struct`, `impl` methods, `opt[T]`, `result[T,E]`, `guard let` | throughout — see `arcade/arcade.sl` for the domain types |
| `??` null-coalescing | `main.sl`'s `PORT`/`TLS_PORT` env var handling |
| `time` (mono/wall/sleep, `duration` arithmetic) | uptime tracking, drain polling, the TLS accept loop's backoff |
| `net` (raw TCP: listen/accept/recv/send/close) | `main.sl`'s plain-HTTP path, `httpkit/httpkit.sl`'s parser working directly on `bytes` |
| `net.tls_*` | `main.sl`'s second listener, sharing the exact same routing as plain HTTP |
| `json` (typed decode/encode, including nested structs and `map[str]Player`) | every `/api/*` route |
| `proc` (`shutdown_requested`, `active_tasks`, `getenv`) | graceful shutdown + drain in `main.sl`, `PORT`/`TLS_PORT` |
| `spawn` (real OS threads, one per connection) | `handle_http_conn`/`handle_tls_conn` |
| `chan[T]` | two uses: (1) as the state mutex described below, (2) is what makes `proc.active_tasks()`-based draining meaningful in the first place |
| local package imports, `pub`, cross-package structs | `httpkit/`, `arcade/`, `content/` — three packages imported by `main.sl` the same way `examples/pkgdemo` does |
| C interop: `extern fn`, `link` | `lib.c` (dice RNG) via `link "slangarcade";`, plus bare libc (`getpid`, `atoi`) needing no `link` at all |
| Lists, maps, `push`, `has`, indexing, iteration | the message wall (`[Message]`) and leaderboard (`map[str]Player`) |

## Two real bugs this demo found (and how they're addressed)

Building this surfaced two genuine gaps — not staged, found by actually
running it under load. Both are left visible in the code and comments
rather than quietly smoothed over, because how they were found and
fixed is as much a "clear picture" of the language as the happy path.

**1. A secondary listener's accept loop can hang shutdown forever.**
`SIGTERM`/`SIGINT` can only ever land on slang's main thread (every
`spawn`ed thread has them blocked in its own mask — see
`stmt.c`'s `spawn` codegen and the `proc` section of the top-level
README). That's exactly what lets a blocked `net.accept()` on the main
thread notice a shutdown signal. But the HTTPS listener in this demo
runs its own accept loop on a *spawned* background thread (so the
main thread stays free to run the plain-HTTP loop) — and a blocking
`net.tls_accept()` there would never be interrupted, staying counted
in `proc.active_tasks()` forever and hanging the drain loop in
`main.sl`. Fixed by putting that listening socket in non-blocking mode
and polling it (see `tls_accept_loop` in `main.sl`) instead of relying
on signal interruption, which only ever works for the main thread's
own blocking calls.

**2. Fixing that revealed a real compiler bug**: an accepted
connection's blocking mode is platform-defined, and on macOS it
inherited `O_NONBLOCK` from the listening socket once *that* was
switched to non-blocking for the fix above — so every accepted TLS
connection silently became non-blocking too, and the very first
`SSL_read` on it failed instantly with "would block," which the
handler read as "connection closed" and hung up before the client had
even sent its request. This was a latent gap in the compiler itself
(`net.accept`/`net.tls_accept` never normalized an accepted socket's
blocking mode), not specific to this app — fixed in
`src/codegen/pkg_net/runtime_net.c` (`sl_net_ensure_blocking`, called
from both `sl_net_accept` and `sl_net_tls_accept`), verified with the
full compiler test suite plus this demo's own concurrent-load test.

**3. Concurrent map/list mutation without synchronization hangs the
process.** Ten simultaneous dice-roll requests, each a separate
`spawn`ed connection handler mutating the shared leaderboard `map`
with no synchronization, deadlocked the server outright — not a rare
data race, a reliable hang under load. This is the language's
documented behavior working as intended ("real concurrency... not an
ownership/borrow checker" — see the top-level README's concurrency
limitations), not a bug to report. The fix is `chan[T]` used as a
mutex: `AppState.lock` is a `chan[bool]` created with one token in it;
`lock_state`/`unlock_state` acquire and release it around every access
to the shared message list, leaderboard, and request counter. See the
comment on `AppState` in `main.sl`.

## Files

```
demo/
  main.sl          entry point: routing, connection handling, startup/shutdown
  lib.c             the C fixture (dice RNG) linked in via `link`/`extern fn`
  run.sh            build lib.c, generate a cert, run the server
  httpkit/          hand-rolled HTTP/1.1 parsing + response building over bytes
  arcade/           domain structs shared between routes and json.decode/encode
  content/          the HTML/CSS/JS, as slang functions returning strings
```
