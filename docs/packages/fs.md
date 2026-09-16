# fs

> Package fs.

POSIX file I/O on integer fds. `open` is read-only; `create` is
write/trunc. `read`/`write`/`close` use the fd. `mkdir` creates one
directory. Every call returns `result[_, str]`. These calls block the
worker — use them for config and small files, not the accept loop.

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

### `fs.write(int, bytes) -> result[i32,str]`

### `fs.close(int) -> result[bool,str]`

### `fs.mkdir(str) -> result[bool,str]`
