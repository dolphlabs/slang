# io

> Package io.

The process's standard streams: what a command-line program needs that
`print`/`println` and `proc.args()` don't already give it. Pure libc, so
importing `io` adds no link flag.

| | |
|---|---|
| `io.read_line()` | `result[opt[str], str]` — one line of stdin, without its newline |
| `io.read_all()` | `result[bytes, str]` — everything until the end of input |
| `io.eprint(s)` / `io.eprintln(s)` | `s` (a `str` or a `fault`) to stderr, nothing added |
| `io.flush()` | flush stdout |
| `io.is_tty(fd)` | `bool` — whether `fd` (0, 1, 2) is a terminal |

```slang
import "io";
import "log";

print("name? ");                         // no io.flush() needed: reading flushes it
let r = io.read_line();
guard let maybe = r else let e = err_of(r) {
    io.eprintln("cannot read input: " + e);
    exit(1);
}
guard let name = maybe else {            // none: the input ended (Ctrl-D, end of pipe)
    exit(0);
}
println("hello, " + name);
```

A loop over every line is the same two guards inside `while true`:

```slang
let total = 0;
while true {
    let r = io.read_line();
    guard let maybe = r else let e = err_of(r) { io.eprintln(e); exit(1); }
    guard let line = maybe else { break; }         // end of input
    total = total + len(line);
}
```

**`opt` inside `result`, on purpose.** The end of input is not a failure —
it is what a filter is *waiting for* — so it is `none`, the way a drained
channel is; a failed read is an `err`. That is the README's own rule
(absent data is `opt`, a bad world is `result`), at the cost of two guards.

**Lines.** `"\n"` or `"\r\n"` ends one and is not returned; an empty line is
`some("")`, which is not `none`. A final line with no terminator is still a
line. Ctrl-D on a terminal ends *one* read — the next `read_line` reads
again, as in a shell — while on a pipe or file every later call is `none`
too.

**Waiting parks the task, not the thread.** On a terminal, a pipe or a
socket, `read_line` and `read_all` wait on the same reactor as
`net.recv`, so other tasks keep running while a person thinks. (Reading
fd 0 with `fs.read` blocks a whole worker thread; with one worker that
stalls the entire program.) A regular file or `/dev/null` never blocks and
is read directly. Before it waits, `io` flushes stdout, so a prompt written
with `print` is on screen before the user types.

**Ctrl-C.** With `proc` imported the shutdown signal is not fatal:
a waiting `read_line` returns `err("interrupted")` and the program can
clean up (without `proc`, Ctrl-C ends the process as usual).

**Limits.** Input is buffered in memory, so one line — or `read_all`'s
whole input — is capped at 256 MiB; past that the call returns an `err`
rather than allocating without bound. stdin is one shared stream: two
tasks reading it at once are memory-safe but see interleaved chunks, so
give it to one task.

`eprint`/`eprintln` write straight to stderr with no timestamp or level —
for the messages a command prints to a person; `log` is for a service's
diagnostics.

## API

### `io.read_line() -> result[opt[str],str]`

### `io.read_all() -> result[bytes,str]`

### `io.eprint(str)`

### `io.eprintln(str)`

### `io.flush()`

### `io.is_tty(int) -> bool`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
