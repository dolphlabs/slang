# flags

> Package flags.

Command-line options, parsed out of `proc.args()`. A slang-source stdlib
package. Declare the flags on a `Set`, parse, read the values back:

```slang
import "flags";
import "proc";

let fs = flags.new("greet", "print a greeting");
fs.add_str("name", "n", "world", "who to greet");
fs.add_int("count", "c", 1, "how many times");
fs.add_bool("loud", "l", false, "shout");
fs.add_list("tag", "t", "label to attach (repeatable)");

let p = fs.parse_or_exit(proc.args());

let greeting = "hello " + p.get_str("name");
if p.get_bool("loud") { greeting = greeting + "!"; }
let i = 0;
while i < p.get_int("count") { println(greeting); i = i + 1; }
for file in p.args() { println("file: " + file); }
```

```
$ greet -n bob -c 2 -l a.txt b.txt
hello bob!
hello bob!
file: a.txt
file: b.txt
$ greet --help
Usage: greet [options] [args...]

print a greeting

Options:
  -n, --name <str>   who to greet (default: "world")
  -c, --count <int>  how many times (default: 1)
  -l, --loud         shout
  -t, --tag <str>    label to attach (repeatable)
  -h, --help         show this help
```

| Declare | Value type |
|---|---|
| `fs.add_str(name, short, default, usage)` | `str` |
| `fs.add_int(name, short, default, usage)` | `int` |
| `fs.add_float(name, short, default, usage)` | `float` |
| `fs.add_bool(name, short, default, usage)` | `bool` |
| `fs.add_list(name, short, usage)` | `[str]`, one entry per occurrence |
| `fs.require(name)` | the flag must appear |
| `fs.set_takes("<file>...")` | positional synopsis on the usage line (`""` for none) |
| `fs.stop_at_first_arg()` | flags end at the first positional (subcommands) |

| Read | |
|---|---|
| `p.get_str(name)` / `get_int` / `get_float` / `get_bool` / `get_list` | the value, or the default |
| `p.is_set(name)` | did the command line set it? |
| `p.args()` | positional arguments, in order |
| `p.wants_help()` | was `-h` / `--help` given? |
| `fs.parse(args)` | `result[Parsed, str]` |
| `fs.parse_or_exit(args)` | `Parsed`; on a usage error prints to stderr and exits 2, on `--help` prints the usage and exits 0 |
| `fs.usage()` | the help text as a `str` |

What a command line may contain:

- **Long flags**: `--name bob` or `--name=bob`. **Short flags**: `-n bob`,
  `-nbob` or `-n=bob`. Give `""` for a flag with no short form.
- **Bools** take no value: `--loud` sets true, `--loud=false` or
  `--no-loud` sets false. Short bools combine, `-lv` is `-l -v`, and a
  value flag may end a cluster: `-lc5`.
- **Positional arguments** may be mixed with flags. `--` ends the flags,
  and a lone `-` is a positional argument (the usual "read stdin"). The
  last occurrence of a flag wins, except a list flag, which collects them.
- A value flag takes the next token as its value even if it starts with
  `-`, so `--offset -5` works. A positional argument that looks like a flag
  needs a `--` before it.

`parse` takes the list exactly as `proc.args()` returns it and skips element
0, the program name. The positionals come back without it, so a subcommand
parses what its parent left with the same call:

```slang
let global = flags.new("tool", "");
global.add_bool("verbose", "v", false, "chatty output");
global.stop_at_first_arg();                  // "push --force" is not ours
let g = global.parse_or_exit(proc.args());   // g.args() == ["push", "--force", "origin"]

let push = flags.new("push", "");
push.add_bool("force", "f", false, "overwrite");
let s = push.parse_or_exit(g.args());        // element 0, "push", is skipped
```

**Two kinds of failure.** What a user can type wrong (an unknown flag, a
missing or malformed value, a required flag left out) comes back as an
`err` from `parse`: bad data, so `result[_, str]`. What only a programmer
can get wrong (a duplicate or empty flag name, a short name longer than one
character, reading a flag that was never declared, `get_int` on a str flag)
panics, because no input can cause it and it should fail the first time the
program runs, not on the user's third flag.

**Why declare, then read.** Go's `flag.String` hands back a pointer that is
filled in later. slang has no references to locals, so the values live on the
`Parsed` result and are read by name. The declaring methods are `add_str` and
so on because `str`, `int`, `float` and `bool` are type keywords.

Not supported: flags that take several values in one occurrence,
`--flag value1 value2`; abbreviations of long names; environment-variable
fallbacks. Set a default from `proc.getenv` yourself when you want one.

## API

### `gc struct Flag`

### `gc struct Set`

The declared flags. Build one with `new`, add flags, then `parse`.

### `gc struct Parsed`

What `parse` found: every declared flag with its value (the default when the command line did not set it), the positional arguments, and whether -h / --help was given.

### `fn new(prog: str, about: str) -> Set`

A flag set for the program `prog`. `about` is one line for the top of the usage text ("" for none).

### `fn add_str(self: Set, name: str, short: str, def: str, usage: str)`

`--name value`, `--name=value`, `-n value`, `-nvalue`. Pass "" as `short` for a flag with no short form.

### `fn add_int(self: Set, name: str, short: str, def: int, usage: str)`

Like add_str, for a base-10 integer.

### `fn add_float(self: Set, name: str, short: str, def: float, usage: str)`

Like add_str, for a float.

### `fn add_bool(self: Set, name: str, short: str, def: bool, usage: str)`

`--name` sets it true, `--name=false` (or `--no-name`) sets it false. Short bool flags combine: `-vq` is `-v -q`.

### `fn add_list(self: Set, name: str, short: str, usage: str)`

A repeatable string flag: `-I a -I b` gives ["a", "b"]. Empty when never given.

### `fn require(self: Set, name: str)`

Make `name` mandatory: `parse` fails if the command line leaves it out (unless --help was asked for). A default is meaningless for a required flag, and the usage text says "required" instead.

### `fn set_takes(self: Set, takes: str)`

What follows the options on the usage line: "<file>...", "[dir]". "" for a program that takes no positional arguments.

### `fn stop_at_first_arg(self: Set)`

Treat the first positional argument, and everything after it, as positional -- even what looks like a flag. Needed for programs with subcommands, where the rest belongs to the subcommand.

### `fn parse(self: Set, args: [str]) -> result[Parsed, str]`

Parse `args` -- proc.args(), or the positional list a parent parse left behind. Element 0 is the program (or subcommand) name and is skipped. Flags and positional arguments may be mixed; `--` ends the flags, and a lone `-` is a positional argument (the usual "stdin").  Fails, with a message fit to show a user, on an unknown flag, a missing or malformed value, or a required flag left out. `-h` and `--help` do not fail: check `wants_help()` on the result.

### `fn parse_or_exit(self: Set, args: [str]) -> Parsed`

`parse` for a program's own command line, with the conventional failure handling: a usage error prints "prog: message" and a pointer to --help on stderr and exits 2; --help prints the usage text on stdout and exits 0.

### `fn usage(self: Set) -> str`

The help text: usage line, the `about` line, then every flag in the order it was declared with its default.

### `fn get_str(self: Parsed, name: str) -> str`

The value of the str flag `name`: what the command line gave, or the default. Panics if no str flag by that name was declared.

### `fn get_int(self: Parsed, name: str) -> int`

### `fn get_float(self: Parsed, name: str) -> float`

### `fn get_bool(self: Parsed, name: str) -> bool`

### `fn get_list(self: Parsed, name: str) -> [str]`

Every value of the list flag `name`, in command-line order.

### `fn is_set(self: Parsed, name: str) -> bool`

Did the command line set `name` -- as opposed to it holding its default? Works for every kind of flag.

### `fn args(self: Parsed) -> [str]`

The positional arguments, in order, without the program name.

### `fn wants_help(self: Parsed) -> bool`

Was -h or --help given?

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
