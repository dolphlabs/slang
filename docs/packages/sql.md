# sql

> Package sql.

A SQLite driver (linked automatically, only when a program imports
`sql`). Connections and prepared statements are opaque `rawptr`
handles, exactly like `net.tls_*`; free them with `sql.close` /
`sql.finalize`. **Every fallible call returns `result[_, str]` whose
error is SQLite's own message** — `no such table: users`, `near
"SELCT": syntax error`, `UNIQUE constraint failed: users.id` — so a
bad query stays as visible as a bad socket read (`guard let … else
let e = err_of(r)`), never a silent `null`. The column getters are
infallible (SQLite coerces types; an out-of-range index is a
programming error, returning `0` / `""`), so they return bare values.

| Function | Signature |
|----------|-----------|
| `sql.open(path)` | `result[rawptr, str]` — `":memory:"` for in-memory |
| `sql.close(db)` | — |
| `sql.exec(db, sql)` | `result[int, str]` — runs statement(s), returns rows changed |
| `sql.last_insert_id(db)` | `int` |
| `sql.prepare(db, sql)` | `result[rawptr, str]` |
| `sql.finalize(st)` | — |
| `sql.reset(st)` | `result[bool, str]` — clears bindings, re-run |
| `sql.bind_int/bind_float/bind_text/bind_blob(st, idx, v)` | `result[bool, str]` — `idx` is 1-based |
| `sql.bind_null(st, idx)` | `result[bool, str]` |
| `sql.step(st)` | `result[bool, str]` — `true` = row ready, `false` = done |
| `sql.col_count(st)` | `int` |
| `sql.col_name(st, i)` / `col_text(st, i)` | `str` — `i` is 0-based |
| `sql.col_int(st, i)` | `int` |
| `sql.col_float(st, i)` | `float` |
| `sql.col_blob(st, i)` | `bytes` |
| `sql.col_is_null(st, i)` | `bool` |

```slang
import "sql";
import "log";

let dr = sql.open("app.db");
guard let db = dr else let e = err_of(dr) {
    log.error("db open: " + e);
    exit(1);
}
sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

let pr = sql.prepare(db, "SELECT id, name FROM users WHERE id > ?");
guard let st = pr else let e = err_of(pr) {
    log.error("prepare: " + e);          // e.g. "no such table: users"
    exit(1);
}
sql.bind_int(st, 1, 0);
while true {
    let sr = sql.step(st);
    guard let more = sr else let e = err_of(sr) { log.error("step: " + e); break; }
    if !more { break; }
    println(to_str(sql.col_int(st, 0)) + " " + sql.col_text(st, 1));
}
sql.finalize(st);
sql.close(db);
```

SQLite calls block the worker — use them for real work off the accept
loop (wrap in a `spawn`ed task), the same caveat as `fs`. One
connection per `rawptr`; there is no pool and no async stepping. For
Postgres, see [`pg`](#pg), which runs on the scheduler instead.

Query complexity is capped per connection so SQLite's recursion stays
inside the task stack: at most **50 terms in a compound `SELECT`**
(`UNION`/`INTERSECT`/`EXCEPT`) and an **expression depth of 400**
(roughly, terms in one `AND`/`OR` chain). SQLite's stock limits of 500
and 1000 allow a single legal query to want ~325KB of C stack, which
would force a task stack far too fat to spawn per connection. Long
`IN` lists, wide result sets, and recursive CTEs are *not* affected —
they don't recurse. Exceeding a cap is a normal error through
`result[_, str]` (`too many terms in compound SELECT`), not a crash.

## API

### `sql.open(str) -> result[rawptr,str]`

### `sql.close(rawptr)`

### `sql.exec(rawptr, str) -> result[int,str]`

### `sql.last_insert_id(rawptr) -> int`

### `sql.prepare(rawptr, str) -> result[rawptr,str]`

### `sql.finalize(rawptr)`

### `sql.reset(rawptr) -> result[bool,str]`

### `sql.bind_int(rawptr, int, int) -> result[bool,str]`

### `sql.bind_float(rawptr, int, float) -> result[bool,str]`

### `sql.bind_text(rawptr, int, str) -> result[bool,str]`

### `sql.bind_blob(rawptr, int, bytes) -> result[bool,str]`

### `sql.bind_null(rawptr, int) -> result[bool,str]`

### `sql.step(rawptr) -> result[bool,str]`

### `sql.col_count(rawptr) -> int`

### `sql.col_name(rawptr, int) -> str`

### `sql.col_is_null(rawptr, int) -> bool`

### `sql.col_int(rawptr, int) -> int`

### `sql.col_float(rawptr, int) -> float`

### `sql.col_text(rawptr, int) -> str`

### `sql.col_blob(rawptr, int) -> bytes`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
