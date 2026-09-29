# proc

> Package proc.

Graceful shutdown and environment variables. `proc.shutdown_requested()`
turns true once the process receives `SIGTERM` or `SIGINT`; a blocked
`net.accept()`/`net.recv()`/`net.dial()` is interrupted the instant the
signal arrives (an `err` result, not a hang), so a listener loop notices
without needing `select` or a timeout.

Handling the signals is opt-in by use. A program that calls
`proc.shutdown_requested()` anywhere — in its own code or in a package it
imports — takes them over: the first `SIGTERM` or `SIGINT` only sets the
flag, and a **second** one ends the process the way the signal would
have, so a drain that never finishes cannot make it unkillable. A program
that never asks keeps the default action: the signal ends it, whether or
not it imports `proc` for anything else (`proc.getenv`, say).

`proc.active_tasks()` counts currently-running `spawn`ed tasks.
`proc.wait_idle()` parks until that count is zero, so a
shutting-down program can drain in-flight work without polling.

```slang
import "net";
import "proc";
import "time";

fn accept_and_serve(lfd: i32) {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return; } // interrupted, or a real error
    spawn serve(cfd);
}

let lr: result[i32, str] = net.listen(8080);
guard let lfd = lr else { exit(1); }

while !proc.shutdown_requested() {
    accept_and_serve(lfd);
}

proc.wait_idle();
```

`proc.getenv(name)` reads an environment variable, returning
`opt[str]` (`none` if unset). `proc.args()` is the process argument
list (`[str]`); `args[0]` is the executable path. To parse options out of it, see
[`flags`](#flags). `proc.cwd()` is the
working directory as `result[str, str]`.

## API

### `proc.shutdown_requested() -> bool`

### `proc.active_tasks() -> int`

### `proc.wait_idle()`

### `proc.getenv(str) -> opt[str]`

### `proc.args() -> [str]`

### `proc.cwd() -> result[str,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
