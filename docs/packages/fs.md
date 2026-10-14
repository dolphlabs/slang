# fs

> Package fs.

POSIX file I/O on integer fds. `open` is read-only; `create` is
write/trunc. `read`/`write`/`close` use the fd; `pread(fd, off, n)` reads
at an offset. `mkdir` creates one directory. Every call returns
`result[_, str]`, except `fstat(fd)`, which is `[kind, size, mtime_sec,
mtime_nsec]` of an open file (kind 0 a regular file, 1 a directory, 2
anything else; `[]` for a closed fd). `realpath(path)` resolves `.`, `..`
and every symlink to an absolute path: what a file server compares with
its root, so a link cannot lead out of it. These calls block the
worker — use them for config and small files, not the accept loop.
To read standard input use [`io`](#io) instead: `fs.read(0, n)` works, but
waits by blocking a whole worker thread, and a program waiting on a person
at a keyboard would stall every other task with it.

```slang
import "fs";

let cr = fs.create("/tmp/note");
guard let fd = cr else { exit(1); }
fs.write(fd, b"hi");
fs.close(fd);

let or = fs.open("/tmp/note");
guard let in_fd = or else { exit(1); }
let rr = fs.read(in_fd, 16);
guard let data = rr else { exit(1); }
fs.close(in_fd);
```

## API

### `fs.open(str) -> result[i32,str]`

### `fs.create(str) -> result[i32,str]`

### `fs.read(int, int) -> result[bytes,str]`

### `fs.pread(int, int, int) -> result[bytes,str]`

### `fs.write(int, bytes) -> result[i32,str]`

### `fs.close(int) -> result[bool,str]`

### `fs.mkdir(str) -> result[bool,str]`

### `fs.realpath(str) -> result[str,str]`

### `fs.fstat(int) -> [int]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
