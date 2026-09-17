# pg

> Package pg.

A **PostgreSQL** client, written in slang over `net`. A query waiting on
the server parks its task like any socket read, so unlike `sql` it does
not block a worker thread: a server can hold many database connections
on a handful of threads. Errors keep the server's own text and SQLSTATE,
through the same `result[_, str]` story as every other package.

```slang
import "pg";
import "time";
import "log";

let dl = until_of(time.mono() + 5000000000);

let pr = pg.new_pool("postgres://app:secret@db.internal/shop", 10);
guard let pool = pr else let e = err_of(pr) {
    log.error("db url: " + e);
    exit(1);
}

let r = pg.pool_query(pool,
    "SELECT id, name, price FROM products WHERE price < $1 ORDER BY id",
    [pg.arg_float(20.0)], dl);
guard let rows = r else let e = err_of(r) {
    log.error("query: " + e);   // ERROR: relation "products" does not exist (SQLSTATE 42P01)
    exit(1);
}
let i = 0;
while i < rows.count {
    println(to_str(pg.get_int(rows, i, 0)) + " " + pg.get_text(rows, i, 1));
    i = i + 1;
}
```

Every call that talks to the server takes a deadline (`until`), like
`httpc`; `until_of(0)` waits indefinitely. For `connect` it covers the
whole connection: DNS lookup, TCP connect, TLS handshake and login.

| Function | Signature |
|---|---|
| `pg.connect(url, deadline)` | `result[Conn, str]` |
| `pg.parse_url(url)` / `pg.connect_config(cfg, deadline)` | `result[Config, str]` / `result[Conn, str]` |
| `pg.query(c, sql, args, deadline)` | `result[Rows, str]` — one statement, `$1`, `$2`… parameters |
| `pg.exec(c, sql, deadline)` | `result[int, str]` — several `;`-separated statements, no parameters; rows affected by the last |
| `pg.close(c)` | — sends Terminate and closes |
| `pg.usable(c)` / `pg.in_transaction(c)` | `bool` |
| `pg.server_param(c, name)` | `opt[str]` — `server_version`, `TimeZone`, … |
| `pg.sqlstate(e)` | `str` — the SQLSTATE in an error, or `""` if it did not come from the server |

**Parameters** travel separately from the SQL text, so a value can never
be parsed as SQL, whatever it contains. Build them with `pg.arg_text(s)`,
`arg_int(n)`, `arg_float(x)` (sent exactly, not rounded), `arg_bool(b)`,
`arg_bytes(b)` (binary, for `bytea`) and `arg_null()`. A query with none
takes `[]`.

**Results** from `query` are buffered whole in a `Rows` (for one too big
for that, see [Streaming](#streaming)): `rows.count`, `rows.columns`
(names), `rows.affected` (from the command tag, so an `INSERT` or
`UPDATE` through `query` reports its row count) and `rows.tag`. Read
cells by row and column index; `pg.col(rows, "name")` finds an index.

| Getter | Reads |
|---|---|
| `pg.get_text(rows, r, c)` | any column, in Postgres's text form (dates, `numeric`, `uuid`, `json`) |
| `pg.get_int(rows, r, c)` | `int2`, `int4`, `int8`, `oid`, and a whole-number `numeric` (what `sum()` of an integer column returns) |
| `pg.get_float(rows, r, c)` | `float4`, `float8`, `numeric`, the integer types |
| `pg.get_bool(rows, r, c)` | `bool` |
| `pg.get_bytes(rows, r, c)` | `bytea` |
| `pg.is_null(rows, r, c)` | whether the cell is NULL |

The getters **panic** on NULL, on a column of a type they do not read,
on an unknown column name and on an index out of range, with a message
naming the column (`column 'email' is NULL in row 3; check pg.is_null
before pg.get_text`). Those are disagreements between the query and the
code reading it — bugs to see, not conditions to handle — and inventing a
`0` or `""` would hide them. A nullable column is checked with `is_null`
first. Like sqlx's `get`, not Go's `Scan`.

##### Pool

`pg.new_pool(url, max_open)` parses the url and connects nothing until
first use. `pool_query` and `pool_exec` take a connection, run, and give
it back, so they cannot leak one. A transaction needs several statements
on one connection, so it uses `acquire` and `release`:

```slang
let cr = pg.acquire(pool, dl);
guard let c = cr else let e = err_of(cr) { return; }
pg.exec(c, "BEGIN", dl);
let moved = pg.query(c, "UPDATE accounts SET balance = balance - $1 WHERE id = $2",
                     [pg.arg_int(100), pg.arg_int(from)], dl);
guard let m = moved else {
    pg.release(pool, c);    // still in the transaction: closed, never reused
    return;
}
pg.exec(c, "COMMIT", dl);
pg.release(pool, c);
```

At most `max_open` connections exist at once; a task that needs one while
all are in use waits, up to its deadline. Idle connections are probed
before reuse and closed after `pool.idle_timeout` (5 minutes). A
connection released while broken, closed or **still inside a
transaction** is closed rather than handed on — the next caller would
otherwise run its statements inside someone else's uncommitted work.
Releasing the same connection twice panics. `pool.dials` and
`pool.reuses` count what the pool did.

##### URLs and TLS

`postgres://user:password@host:port/database?param=value`, with `%`
escapes in any part. The port defaults to 5432 and the database to the
user name. Recognised parameters are `sslmode`, `sslrootcert` (a CA
bundle to verify against, for providers that sign with their own CA) and
`application_name`, plus `host` and `port`, which override the ones in the
authority, as in libpq. **Anything else is an error, not ignored**: a
misspelt `sslmdoe=require` that was quietly dropped would connect in
cleartext and nothing would ever say so.

| `sslmode` | |
|---|---|
| `disable` | cleartext |
| `require`, `verify-full` | TLS, with the certificate chain **and hostname verified** |
| `prefer`, `allow` | refused: they fall back to cleartext when TLS fails, which is exactly what a man in the middle arranges |
| `verify-ca` | refused: it does not check the hostname |

This differs from libpq on purpose: libpq's `require` encrypts without
checking who answered. Without `sslmode`, the default is `require` —
except for a loopback host (`localhost`, `127.x`, `::1`), where it is
`disable`, because traffic that never leaves the machine gains nothing
from TLS and local servers rarely have it set up. A server that does not
offer TLS gets a message saying to add `sslmode=disable`.

**Unix-domain sockets** are named by their directory, as libpq does:
`postgres://app@%2Fvar%2Frun%2Fpostgresql/shop` (the host
percent-encoded) or `postgres://app@/shop?host=/var/run/postgresql`. The
socket file is `<dir>/.s.PGSQL.<port>`. Postgres does not use TLS over a
socket, so `sslmode` defaults to `disable` there and `require` is an
error.

Authentication: SCRAM-SHA-256 (the default since Postgres 14), md5 and
cleartext password. SCRAM checks that the **server** knows the password
too: a server that skips its proof, or sends a wrong one, is refused.

##### Timeouts and errors

A server-side error — a syntax error, a constraint violation — leaves the
connection usable. Anything that leaves the stream at an unknown point
breaks it: an I/O error, a protocol violation, a deadline. After a
`"timeout"` the server may still be running the query, so the driver asks
it to stop with a cancel request on a separate connection, from its own
task, and returns immediately. A broken connection only returns
`connection is broken: <why>`.

```slang
let r = pg.query(c, "INSERT INTO users (email) VALUES ($1)", [pg.arg_text(email)], dl);
guard let ok_ = r else let e = err_of(r) {
    if pg.sqlstate(e) == "23505" {     // unique_violation
        return respond(409, "email already registered");
    }
    return respond(500, "database error");
}
```

A `Conn` is safe to share between tasks (calls take turns), but a pool is
the better tool for that.

##### Streaming

`pg.stream` runs a query like `query` but hands the rows over one at a
time, so memory holds one row however large the result, and the server
is held back by TCP flow control rather than the client reading ahead:

```slang
let sr = pg.stream(c, "SELECT id, body FROM events ORDER BY id", [], dl);
guard let rows = sr else let e = err_of(sr) { return; }
while true {
    let nr = pg.next_row(c, rows, dl);
    guard let more = nr else let e = err_of(nr) { log.error(e); break; }
    if !more { break; }
    archive(pg.get_int(rows, 0, 0), pg.get_text(rows, 0, 1));   // always row 0
}
```

Each `next_row` replaces the row in `rows`, read at index 0; after the
last, `rows.affected` and `rows.tag` are set. A server error part way
through comes from `next_row`, after the rows before it. While a stream
is open the connection serves nothing else — other calls fail with
`connection is busy` — so read it to the end or call
`pg.stream_close(c, rows, dl)`. That asks the server to cancel the query,
waits until the request has been delivered (so it cannot hit a *later*
query on the same connection), then drops whatever was already sent. A
connection released to a pool mid-stream is closed.

| Function | Signature |
|---|---|
| `pg.stream(c, sql, args, deadline)` | `result[Rows, str]` |
| `pg.next_row(c, rows, deadline)` | `result[bool, str]` — `false` after the last row |
| `pg.stream_close(c, rows, deadline)` | `result[bool, str]` |

##### COPY

`COPY … FROM STDIN` bulk-loads data in COPY's text or CSV format, far
faster than one `INSERT` per row; `COPY … TO STDOUT` dumps it.

```slang
let n = pg.copy_from(c, "COPY users (id, email) FROM STDIN (FORMAT csv)",
                     to_bytes("1,a@example.com\n2,b@example.com\n"), dl);
let dump = pg.copy_to(c, "COPY users TO STDOUT (FORMAT csv)", dl);
```

| Function | Signature |
|---|---|
| `pg.copy_from(c, sql, data, deadline)` | `result[int, str]` — rows loaded |
| `pg.copy_in_start(c, sql, deadline)` | `result[bool, str]` |
| `pg.copy_in_send(c, data, deadline)` | `result[bool, str]` — any split, not only whole rows |
| `pg.copy_in_end(c, deadline)` | `result[int, str]` — rows loaded |
| `pg.copy_in_abort(c, reason, deadline)` | `result[bool, str]` — the server discards everything |
| `pg.copy_to(c, sql, deadline)` | `result[bytes, str]` — buffered, up to the 256 MiB limit |
| `pg.copy_out_start(c, sql, deadline)` | `result[bool, str]` |
| `pg.copy_out_next(c, deadline)` | `result[opt[bytes], str]` — a row's worth, `none` at the end |

The start/send/end and start/next forms stream, for data that should not
be held in memory at once. A bad row fails the whole COPY — the error
comes from `copy_in_end` (or `copy_from`) with its SQLSTATE, and nothing
was loaded. A COPY of the wrong direction is refused with `not a COPY …
FROM STDIN statement`, and a COPY through `query` or `exec` fails with a
message pointing here, the connection intact either way. Only the text
and CSV formats are meant: binary COPY data passes through untouched but
this package does not build or parse it.

##### LISTEN / NOTIFY

```slang
pg.listen(c, "jobs", dl);
while true {
    let wr = pg.wait_notification(c, until_of(time.mono() + 30000000000));
    guard let got = wr else let e = err_of(wr) { log.error(e); break; }
    guard let note = got else { continue; }        // 30s with nothing: none
    run_job(note.payload);
}
```

| Function | Signature |
|---|---|
| `pg.listen(c, channel, deadline)` / `pg.unlisten(c, channel, deadline)` | `result[bool, str]` — `unlisten(c, "*", dl)` for all |
| `pg.notify(c, channel, payload, deadline)` | `result[bool, str]` |
| `pg.wait_notification(c, deadline)` | `result[opt[Notification], str]` — `pid`, `channel`, `payload` |

Channel names are quoted as identifiers, so any name is safe to pass.
Notifications that arrive during other calls — even in the middle of a
query's result — are queued on the connection (up to 10,000;
`c.notes_dropped` counts any beyond that) and handed out oldest first.
**Reaching the deadline in `wait_notification` returns `none` and leaves
the connection usable**, unlike every other call: waiting is the point,
and a message cut off by the deadline is kept and completed by the next
wait. A server that ends the session while one waits (an administrator's
`pg_terminate_backend`, a restart) is an error with its SQLSTATE. Listen
on a connection of its own, not a pooled one: a pooled connection with a
notification waiting fails the pool's idle probe and is closed.

##### Limits

A driver trusts the server with its memory, so what it will buffer is
capped: one protocol message at 256 MiB, and one result at 256 MiB of
cell data, which is an error rather than an allocation. A SCRAM server may
ask for at most 1,000,000 PBKDF2 iterations (Postgres uses 4096).

Measured against Postgres 16 in Docker on the development Mac: 1M rows
of two columns in about 2.1s and 150MB, a single 20MB value in about
0.3s.

**Not supported:** named prepared statements, binary result format,
building or parsing binary COPY data, Kerberos/GSSAPI, SCRAM channel
binding (`SCRAM-SHA-256-PLUS`), multiple hosts in one url, and SASLprep
normalisation of non-ASCII passwords (an ASCII password is unaffected).

## API

### `gc struct Config`

### `gc struct Conn`

### `gc struct Notification`

A NOTIFY delivered to a connection that LISTENs on its channel.

### `gc struct Arg`

A query parameter. Build one with arg_text, arg_int, arg_float, arg_bool, arg_bytes or arg_null.

### `gc struct Rows`

A buffered result. Read cells with get_text / get_int / get_float / get_bool / get_bytes, by row and column index; col() finds an index by name.

### `fn parse_url(url: str) -> result[Config, str]`

postgres://user:password@host:port/database?sslmode=require  Recognised parameters: sslmode, sslrootcert, application_name, host and port. Any other parameter is an error rather than ignored: a misspelt "sslmdoe=require" that was silently dropped would connect in the clear, and nothing would ever say so.  sslmode: disable      cleartext. require      TLS, certificate and hostname verified. verify-full  the same as require (the libpq spelling of it). prefer, allow, verify-ca are refused. The first two fall back to cleartext when TLS fails, which is exactly what an attacker in the middle would arrange; verify-ca checks the chain but not the host.  With no sslmode the default is "require" -- except for a loopback host, where it is "disable", because traffic that never leaves the machine gains nothing from TLS and a local development server almost never has it configured.  A Unix-domain socket is named by its DIRECTORY, as libpq does: either percent-encoded as the host (postgres://app@%2Fvar%2Frun%2Fpostgresql/db) or as ?host=/var/run/postgresql. The socket file is <dir>/.s.PGSQL.<port>. Postgres does not use TLS over one, so sslmode defaults to disable and asking for require is an error.

### `fn sqlstate(e: str) -> str`

The SQLSTATE of an error returned by this package, or "" when the error did not come from the server (a dial failure, a timeout).  if pg.sqlstate(e) == "23505" { /* unique_violation */ }

### `gc struct Scram`

One SCRAM-SHA-256 exchange (RFC 5802, RFC 7677), as pure functions of its inputs, so the published test vector can check it.

### `fn scram_client_final(password: str, client_first_bare: str,`

### `fn connect(url: str, deadline: until) -> result[Conn, str]`

### `fn connect_config(cfg: Config, deadline: until) -> result[Conn, str]`

The deadline bounds the whole connection: the lookup, the TCP connect, the TLS handshake and the startup and authentication exchange.

### `fn close(c: Conn)`

Ends the session politely (Terminate) and closes the socket. Safe to call on a broken or already-closed connection.

### `fn usable(c: Conn) -> bool`

Is the connection still usable? False once it has been closed or has broken; a false Conn only ever returns errors.

### `fn in_transaction(c: Conn) -> bool`

Inside a transaction block (including a failed one that still needs ROLLBACK)?

### `fn server_param(c: Conn, name: str) -> opt[str]`

A server setting reported at startup or after SET: "server_version", "TimeZone", "standard_conforming_strings", ...

### `fn arg_text(s: str) -> Arg`

### `fn arg_int(n: int) -> Arg`

### `fn arg_float(x: float) -> Arg`

Sent as the shortest text that reads back as exactly this float: to_str's six significant digits would round it.

### `fn arg_bool(b: bool) -> Arg`

### `fn arg_bytes(b: bytes) -> Arg`

Sent in binary, so any byte values -- NULs included -- arrive intact. For a bytea column.

### `fn arg_null() -> Arg`

### `fn query(c: Conn, sql: str, args: [Arg], deadline: until)`

Runs one query with parameters ($1, $2, ...) through the extended protocol: the values travel separately from the SQL text, so they can never be parsed as SQL. Returns every row, buffered; for a result too big to hold at once, use stream().

### `fn exec(c: Conn, sql: str, deadline: until) -> result[int, str]`

Runs SQL with no parameters through the simple protocol, which accepts several statements separated by semicolons -- a migration, a schema. Returns the rows affected by the last statement. Rows a statement returns are read and discarded.  Never build `sql` from untrusted input: use query() and parameters.

### `fn stream(c: Conn, sql: str, args: [Arg], deadline: until)`

### `fn next_row(c: Conn, rows: Rows, deadline: until) -> result[bool, str]`

Reads the next row of a stream into `rows` (at index 0). Returns false once there are no more; rows.affected and rows.tag are set then.

### `fn stream_close(c: Conn, rows: Rows, deadline: until) -> result[bool, str]`

Ends a stream early. The server is asked to cancel the query first -- and that request is seen through before the rest is drained, so it can never land on a LATER query on this connection -- then whatever it had already sent is read and dropped. The connection is then free.

### `fn copy_in_start(c: Conn, sql: str, deadline: until) -> result[bool, str]`

Starts COPY ... FROM STDIN. Send data with copy_in_send, then finish with copy_in_end -- or copy_in_abort, which rolls the COPY back.

### `fn copy_in_send(c: Conn, data: bytes, deadline: until) -> result[bool, str]`

Sends COPY data. It need not end on a row boundary; the server reassembles it. An error in the data is reported by copy_in_end.

### `fn copy_in_end(c: Conn, deadline: until) -> result[int, str]`

Ends the COPY. Returns the number of rows loaded, or the server's error about the data -- in which case nothing was loaded.

### `fn copy_in_abort(c: Conn, reason: str, deadline: until) -> result[bool, str]`

Abandons the COPY: the server discards everything sent. Ok once the server has confirmed; its "COPY from stdin failed" is the expected answer, not an error.

### `fn copy_from(c: Conn, sql: str, data: bytes, deadline: until)`

COPY ... FROM STDIN in one call. Returns the rows loaded.  pg.copy_from(c, "COPY users (id, email) FROM STDIN (FORMAT csv)", to_bytes("1,a@example.com\n2,b@example.com\n"), dl)

### `fn copy_out_start(c: Conn, sql: str, deadline: until) -> result[bool, str]`

Starts COPY ... TO STDOUT. Read it with copy_out_next.

### `fn copy_out_next(c: Conn, deadline: until) -> result[opt[bytes], str]`

The next piece of COPY output -- in text and CSV formats, one row -- or none when it is complete.

### `fn copy_to(c: Conn, sql: str, deadline: until) -> result[bytes, str]`

COPY ... TO STDOUT in one call, buffered (up to the 256 MiB result limit; stream a larger one with copy_out_start / copy_out_next).

### `fn listen(c: Conn, channel: str, deadline: until) -> result[bool, str]`

### `fn unlisten(c: Conn, channel: str, deadline: until) -> result[bool, str]`

"*" stops listening on every channel.

### `fn notify(c: Conn, channel: str, payload: str, deadline: until)`

### `fn wait_notification(c: Conn, deadline: until)`

The oldest queued notification, or waits for one until the deadline: none then. Unlike every other call, reaching the deadline here is not an error and does not break the connection -- waiting is the point.

### `fn col(rows: Rows, name: str) -> int`

The index of the column called `name`. Panics if there is none: the query and the code reading it disagree, which is a bug, not a condition to handle.

### `fn is_null(rows: Rows, r: int, c: int) -> bool`

### `fn get_text(rows: Rows, r: int, c: int) -> str`

Any column, in Postgres's text form: numbers, dates, uuid and json all arrive this way.

### `fn get_int(rows: Rows, r: int, c: int) -> int`

int2, int4, int8 and oid.

### `fn get_float(rows: Rows, r: int, c: int) -> float`

float4, float8, numeric, and the integer types. A numeric too precise for a double is rounded; read it with get_text to keep every digit.

### `fn get_bool(rows: Rows, r: int, c: int) -> bool`

### `fn get_bytes(rows: Rows, r: int, c: int) -> bytes`

bytea, decoded from the server's hex output format.

### `gc struct Pool`

A bounded set of connections to one database, shared by any number of tasks.

### `fn new_pool(url: str, max_open: int) -> result[Pool, str]`

Parses the url; connects nothing until the first acquire.

### `fn acquire(p: Pool, deadline: until) -> result[Conn, str]`

A connection for the caller's exclusive use, until release(). Prefer pool_query / pool_exec, which cannot forget to release; acquire is for a transaction, which needs several statements on one connection.

### `fn release(p: Pool, c: Conn)`

Returns a connection to the pool. One that is broken, closed, or still inside a transaction is closed instead: handing an open transaction to the next caller would run its statements inside someone else's uncommitted work.

### `fn pool_query(p: Pool, sql: str, args: [Arg], deadline: until)`

### `fn pool_exec(p: Pool, sql: str, deadline: until) -> result[int, str]`

### `fn pool_close(p: Pool)`

Closes every idle connection. Connections in use are closed as they are released; acquire fails from now on.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
