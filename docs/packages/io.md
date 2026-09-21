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
| `io.term_width()` / `io.term_height()` | `opt[int]` — columns / rows of the terminal; `none` without one |
| `io.read_secret()` | `result[opt[str], str]` — like `read_line`, with echo off |
| `io.raw_on()` / `io.raw_off()` | `result[bool, str]` — key-at-a-time input on / off |
| `io.read_key()` | `result[opt[str], str]` — one key press, by name |

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

##### The terminal

```slang
import "io";

// a password: nothing is echoed while it is typed
print("password: ");
let r = io.read_secret();
guard let maybe = r else let e = err_of(r) { io.eprintln(e); exit(1); }
let password = maybe ?? "";

// wrap to the window; a pipe or a file has no width
let width = io.term_width() ?? 80;
```

`read_secret` is `read_line` with the terminal's echo off for the length of
the read. The Enter is not echoed either, so it writes the newline for you.
When stdin is not a terminal (a pipe, a file, a test) it is exactly
`read_line`: nothing to turn off. `term_width` and `term_height` ask the
terminal every time, so they follow a resized window — poll them, there is
no resize event. They look at stdout, then stderr, then stdin, and are `none`
when none of the three is a terminal.

**Key by key.** `raw_on` switches stdin from line-at-a-time to key-at-a-time:
no line editing, no echo, and each key press is available as it happens.
`read_key` names it:

```slang
let r = io.raw_on();
guard let ok = r else let e = err_of(r) { io.eprintln(e); exit(1); }   // stdin is not a terminal
while true {
    let k = io.read_key();
    guard let maybe = k else let e = err_of(k) { break; }
    guard let key = maybe else { break; }                              // end of input
    if key == "q" || key == "esc" { break; }
    if key == "up" { println("up"); }
}
io.raw_off();
```

| Key | Name |
|---|---|
| a printable character (a whole UTF-8 character) | itself: `"a"`, `"é"`, `" "` |
| Enter, Tab, Backspace | `"enter"`, `"tab"`, `"backspace"` |
| Escape | `"esc"` |
| Ctrl with a letter | `"ctrl-a"` … `"ctrl-z"` |
| Alt with a key | `"alt-x"` |
| cursor and editing keys | `"up"` `"down"` `"left"` `"right"` `"home"` `"end"` `"insert"` `"delete"` `"pageup"` `"pagedown"` |
| function keys | `"f1"` … `"f12"` |
| with modifiers | `"ctrl-right"`, `"shift-up"`, `"ctrl-shift-left"`, `"shift-tab"` — always in the order ctrl, alt, shift |

Anything else is `"unknown"`, and it is consumed whole, so a mouse report or
an unfamiliar sequence cannot leak into the next key. `read_key` waits like
`read_line` does, parking the task and not the thread, and also works on a
pipe, where it decodes the same bytes.

A lone Escape and the first byte of an escape sequence are the same byte;
what follows it within 50 ms is part of the sequence, and silence means the
Escape key. Over a slow link a sequence split across that gap reads as an
Escape followed by its tail.

**The terminal is put back.** A program that dies while the terminal is raw
leaves the person's shell with no echo and no line editing, so restoring is
not left to the caller. The terminal's original settings are saved once and
restored when the last of `raw_off` and `read_secret` ends, and also:

- when the program exits — `exit()`, a panic in the main task, falling off
  the end of `main` — so a forgotten `raw_off` costs nothing;
- when SIGINT, SIGTERM, SIGHUP, SIGQUIT or SIGABRT ends the process
  (only where the program has not installed its own handling for them).

Raw mode leaves signals on, so **Ctrl-C still works**: with `proc` imported it
makes the next `read_key` return `err("interrupted")`; without it, it ends
the process, and the terminal is restored first. It also leaves output
processing on, so `"\n"` still starts a new line. Not covered: `SIGKILL`
and crashes cannot be caught, and Ctrl-Z stops the process with the terminal
still raw.

`raw_on` fails with `"stdin is not a terminal"` when it is not one, so a
program can fall back to line input when it is run from a script.

## API

### `io.read_line() -> result[opt[str],str]`

### `io.read_all() -> result[bytes,str]`

### `io.eprint(str)`

### `io.eprintln(str)`

### `io.flush()`

### `io.is_tty(int) -> bool`

### `io.term_width() -> opt[int]`

### `io.term_height() -> opt[int]`

### `io.read_secret() -> result[opt[str],str]`

### `io.raw_on() -> result[bool,str]`

### `io.raw_off() -> result[bool,str]`

### `io.read_key() -> result[opt[str],str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
