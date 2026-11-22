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
Called from a spawned task, neither counts the caller (nor, for
`wait_idle`, other tasks also waiting in it), so a task can drain the
rest without waiting for itself; every test under `slangc test` is such
a task.

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

`proc.wait_idle_until(deadline)` is `wait_idle` with a limit: true once
the program is idle, false if the deadline passed first, so a drain can
give up on a stuck connection instead of holding the shutdown forever.

##### Restarting without dropping connections

A new version of a server can take over the old one's listening sockets,
so the port never stops accepting. The old process starts the new one
with `proc.spawn_fds`, which passes the listeners as fds 3, 4, ... and
sets `LISTEN_FDS` to their count (the systemd socket-activation
convention); the new process takes them with `net.inherited()`:

```slang
import "net";
import "proc";
import "time";

// at startup: the parent's listeners if there are any, our own otherwise
let inh = net.inherited();
let lfd = -1 as i32;
if len(inh) > 0 {
    lfd = inh[0];
} else {
    lfd = net.listen(8080) ?? (-1 as i32);
}

// on a restart request: start the new binary on the same socket, stop
// accepting, and drain what is in flight for up to 30 seconds
let noenv: [str] = [];
let sr = proc.spawn_fds(["/srv/app/bin/server"], noenv, "", 0, [lfd]);
net.close(lfd);
proc.wait_idle_until(until_of(time.mono() + 30000000000));
exit(0);
```

`net.inherited()` returns `[]` when nothing was passed. It also accepts
listeners from systemd itself (checking `LISTEN_PID` when set), and it
clears the variables once read, so this program's own children do not
take the fds for theirs. Every other fd stays out of the child: sockets
and files are close-on-exec.

`proc.getenv(name)` reads an environment variable, returning
`opt[str]` (`none` if unset). `proc.args()` is the process argument
list (`[str]`); `args[0]` is the executable path. To parse options out of it, see
[`flags`](#flags). `proc.cwd()` is the
working directory as `result[str, str]`.

## API

### `proc.shutdown_requested() -> bool`

### `proc.active_tasks() -> int`

### `proc.wait_idle()`

### `proc.wait_idle_until(until) -> bool`

### `proc.getenv(str) -> opt[str]`

### `proc.args() -> [str]`

### `proc.cwd() -> result[str,str]`

### `proc.spawn([str], [str], str, int) -> result[int,str]`

### `proc.spawn_fds([str], [str], str, int, NA_ARR_I32) -> result[int,str]`

### `proc.kill(int, int) -> result[bool,str]`

### `proc.wait(int, until) -> result[int,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
