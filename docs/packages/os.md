# os

> Package os.

The operating system *around* a program: the environment, the process,
and everything you can ask or do about a path without opening it. Pure
libc, so importing `os` adds no link flag.

**The `fs`/`os` boundary**: `fs` owns open file **handles** and their
contents; `os` owns paths you have not opened. `fs.mkdir` predates that
split and stays where it is rather than breaking existing programs.

| | |
|---|---|
| `os.setenv(k, v)` / `os.unsetenv(k)` | `result[bool, str]` |
| `os.environ()` | `[str]` of `KEY=VALUE` |
| `os.pid()` / `os.tmpdir()` | `int` / `str` |
| `os.hostname()` | `result[str, str]` |
| `os.exists(p)` / `os.is_dir(p)` / `os.is_file(p)` | `bool` |
| `os.size(p)` / `os.mtime(p)` | `result[int, str]` |
| `os.read_dir(p)` | `result[[str], str]` |
| `os.remove(p)` / `os.rename(a, b)` | `result[bool, str]` |

```slang
import "os";

// serve a static file, the shape this package exists for
if !os.is_file(path) {
    return not_found();
}
let sr = os.size(path);
guard let n = sr else let e = err_of(sr) {
    log.error("stat " + path + ": " + e);      // "No such file or directory"
    return server_error();
}
```

The three predicates are bare `bool` on purpose. "Does this exist" has
two useful answers: a missing path and an unreadable parent are both
"no, you cannot use it", and code branching on the difference is racing
anyway — the answer can change between the check and the use. The
accessors return a value that has to come from somewhere, so those
carry the errno text.

`environ()` is a list rather than a map because an environment may
legally hold a repeated key, and a map would silently drop one.
`read_dir` returns entry names without `.` and `..`, since forgetting
to filter those is how a directory walk becomes an infinite loop.
`remove` takes files and empty directories alike, so a caller need not
know which it has.

`proc.getenv`, `proc.args` and `proc.cwd` stay in `proc`; `os` adds
what `proc` has no answer for rather than duplicating it.

## API

### `os.setenv(str, str) -> result[bool,str]`

### `os.unsetenv(str) -> result[bool,str]`

### `os.environ() -> [str]`

### `os.pid() -> int`

### `os.hostname() -> result[str,str]`

### `os.tmpdir() -> str`

### `os.exists(str) -> bool`

### `os.is_dir(str) -> bool`

### `os.is_file(str) -> bool`

### `os.size(str) -> result[int,str]`

### `os.mtime(str) -> result[int,str]`

### `os.read_dir(str) -> result[[str],str]`

### `os.remove(str) -> result[bool,str]`

### `os.rename(str, str) -> result[bool,str]`
