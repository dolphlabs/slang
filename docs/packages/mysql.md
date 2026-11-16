# mysql

> Package mysql.

A MySQL and MariaDB client over TCP, TLS or a Unix socket, with prepared
statements, streamed results and a pool. The API matches `pg`'s, so code
moves between the two with little change.

```slang
import "mysql";

let cr = mysql.connect("mysql://app:secret@db.internal:3306/shop", deadline);
guard let c = cr else let e = err_of(cr) { panic(e); }

let r = mysql.query(c, "SELECT id, name, price FROM items WHERE price < ?",
                    [mysql.arg_decimal(limit)], deadline);       // result[Rows, str]
guard let rows = r else let e = err_of(r) { panic(e); }
let items: result[[Item], str] = mysql.rows_as(rows);           // by column name
mysql.get_text(rows, 0, mysql.col(rows, "name"));

let ir = mysql.query(c, "INSERT INTO items (name) VALUES (?)", [mysql.arg_text("pen")], deadline);
guard let ins = ir else let e = err_of(ir) { panic(e); }
ins.last_insert_id;                                              // the AUTO_INCREMENT value

mysql.exec(c, "BEGIN; UPDATE stock SET n = n - 1 WHERE id = 7; COMMIT", deadline);   // several statements

let pr = mysql.new_pool(url, 16);                                // shared by any number of tasks
guard let p = pr else let e = err_of(pr) { panic(e); }
mysql.pool_query(p, "SELECT 1", [], deadline);
```

**query and exec.** `query` runs one statement with `?` parameters, as a
server-side prepared statement cached per connection (256 by default,
`statement_cache=N`), so parameter values never pass through the SQL
text. It returns the rows, or for an INSERT or UPDATE an empty result
whose `affected` and `last_insert_id` say what it did. `exec` sends text
and runs any number of statements: migrations, schema, `BEGIN … COMMIT`.

**Results** read like `pg`'s: `col`, `is_null`, `get_text`, `get_int`,
`get_float`, `get_bool` (tinyint(1)), `get_bytes` (BLOB and BINARY,
NULs intact), `get_time` (DATETIME, TIMESTAMP and DATE, read as UTC),
`get_decimal` (exact), and `rows_as[T]`, which binds by column name
through the same compiled decoder as `pg.rows_as`. Values past 2^63 in a
BIGINT UNSIGNED arrive exactly as text. `stream` with `next_row` reads a
large result one row at a time. A result held whole is bounded at
256 MiB.

**Connecting.** `sslmode=require` (the default except for loopback
hosts and Unix sockets) means TLS with the certificate and host name
verified; `sslrootcert=` names a CA bundle. `prefer` is refused, because
falling back to cleartext is what an attacker in the middle arranges.
Supported authentication:

- `mysql_native_password` (MariaDB's default)
- `caching_sha2_password` (MySQL 8's default)
- `sha256_password`
- `mysql_clear_password` (over TLS only)
- switching between them when the server asks

When `caching_sha2_password` needs the password itself, it goes over
TLS or a Unix socket. Without either, it is encrypted with RSA-OAEP to
`server_public_key=/path/key.pem`. Fetching the key from the server is
only done with `allow_public_key_retrieval=true`, since on an
unencrypted connection anyone in the middle can send their own key.
`time_zone=+00:00` sets the session time zone after connecting.

**Failures.** Errors read `mysql: ERROR 1062 (23000): Duplicate entry
…`; `mysql.error_code(e)` and `mysql.sqlstate(e)` take them apart. A
server error leaves the connection usable. A timeout or I/O error breaks
it, and after a timeout the statement is killed from a second connection
(`KILL QUERY`), so it does not run on. The server is never sent a local
file (`LOAD DATA LOCAL` is not offered).

**Cost.** Cells live in the connection's receive buffers, a handful of
objects per result, and binary-protocol numbers and dates are written
into one more. Against a MySQL 8.4 container, 100,000 rows of three
columns buffer in about 130 ms. A point query takes about 0.35 ms, which
is Docker's network round trip: a bare `mysql.ping` costs the same.

## API

### `gc struct Config`

### `fn parse_url(url: str) -> result[Config, str]`

mysql://user:password@host:port/database?sslmode=require  Parameters: sslmode (disable, require; verify-full is require), sslrootcert (a CA bundle), server_public_key (a PEM file), allow_public_key_retrieval (true), time_zone (e.g. +00:00), statement_cache (0 to 65536). Any other parameter is an error: a misspelt sslmode silently dropped would connect in the clear.  TLS is required by default, except to a loopback host or over a Unix socket (host=/path/to/mysqld.sock, or the path percent-encoded as the host), where it is off.

### `gc struct Conn`

### `fn connect(url: str, deadline: until) -> result[Conn, str]`

### `fn connect_config(cfg: Config, deadline: until) -> result[Conn, str]`

The deadline covers the whole connection: the lookup, the TCP connect, TLS, authentication and any time_zone setting.

### `fn close(c: Conn)`

Ends the session politely (COM_QUIT) and closes the socket.

### `fn usable(c: Conn) -> bool`

Is the connection still usable? False once closed or broken.

### `fn in_transaction(c: Conn) -> bool`

Inside a transaction (as the server last reported)?

### `fn server_version(c: Conn) -> str`

The server's version string ("8.4.3", "11.4.4-MariaDB-...").

### `fn connection_id(c: Conn) -> int`

The server's id for this connection (what KILL takes).

### `fn last_insert_id(c: Conn) -> int`

The AUTO_INCREMENT value the last statement generated, and the rows it changed, as the server reported them.

### `fn affected_rows(c: Conn) -> int`

### `fn ping(c: Conn, deadline: until) -> result[bool, str]`

Asks the server whether it is there (COM_PING).

### `fn sqlstate(e: str) -> str`

The SQLSTATE of an error from this package ("23000"), or "" when the error did not come from the server.

### `fn error_code(e: str) -> int`

The server's error number (1062 for a duplicate key), or 0.

### `fn native_password_scramble(password: str, nonce: bytes) -> bytes`

mysql_native_password: SHA1(pw) XOR SHA1(nonce + SHA1(SHA1(pw))).

### `fn sha2_password_scramble(password: str, nonce: bytes) -> bytes`

caching_sha2_password: SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + nonce).

### `gc struct Pool`

A bounded set of connections to one database, shared by any number of tasks.

### `fn new_pool(url: str, max_open: int) -> result[Pool, str]`

Parses the url; connects nothing until the first acquire.

### `fn acquire(p: Pool, deadline: until) -> result[Conn, str]`

A connection for the caller's exclusive use, until release(). Prefer pool_query / pool_exec, which cannot forget to release; acquire is for a transaction, which needs several statements on one connection.

### `fn release(p: Pool, c: Conn)`

Returns a connection to the pool: to the oldest waiting task if there is one, else to the idle list. One that is broken, closed, or still inside a transaction is closed instead, and its slot passed on: handing an open transaction to the next caller would run its statements inside someone else's uncommitted work.

### `fn pool_query(p: Pool, sql: str, args: [Arg], deadline: until) -> result[Rows, str]`

### `fn pool_exec(p: Pool, sql: str, deadline: until) -> result[int, str]`

### `fn pool_close(p: Pool)`

Closes every idle connection and fails every waiting acquire. Connections in use are closed as they are released; acquire fails from now on.

### `gc struct Arg`

A query parameter: a MySQL type and its binary-protocol bytes.

### `fn arg_text(s: str) -> Arg`

### `fn arg_int(n: int) -> Arg`

### `fn arg_float(x: float) -> Arg`

Sent as an 8-byte double: exactly the value, no decimal text between.

### `fn arg_bool(b: bool) -> Arg`

### `fn arg_bytes(b: bytes) -> Arg`

Any bytes, NULs included, for a BLOB or BINARY column.

### `fn arg_null() -> Arg`

### `fn arg_time(t: timez.Time) -> Arg`

An instant, as UTC "YYYY-MM-DD HH:MM:SS.ffffff": DATETIME has no time zone, so the convention (UTC) is the program's to keep -- see the time_zone url parameter for TIMESTAMP columns.

### `fn arg_decimal(d: decimal.Decimal) -> Arg`

A decimal for a DECIMAL column, as its exact text.

### `gc struct Rows`

A buffered result. Cells live in a few chunks -- the connection's own receive buffers, plus one for values the binary protocol sends as numbers -- rather than one object per cell, so a large result costs the collector a handful of objects. types are Postgres-style codes (see mysql_code), which is what lets rows_as share pg's compiled decoder.

### `fn rows_as[T](rows: Rows) -> result[[T], str]`

Every row as a struct or map, bound by exact column name: SQL NULL becomes none, an incompatible cell a named error. Compiler-backed (pg's decoder), with no JSON in between.

### `fn query(c: Conn, sql: str, args: [Arg], deadline: until) -> result[Rows, str]`

Runs one statement with ? parameters as a prepared statement. A SELECT returns its rows; anything else an empty result whose affected and last_insert_id say what it did.

### `fn exec(c: Conn, sql: str, deadline: until) -> result[int, str]`

Runs SQL as text, any number of statements separated by semicolons (a migration, a schema). Returns the rows the statements changed, all together; the rows of any SELECT among them are read and dropped.

### `fn stream(c: Conn, sql: str, args: [Arg], deadline: until) -> result[Rows, str]`

Starts a query whose rows are read one at a time with next_row, for results too large to hold. The connection is busy until the last row has been read or stream_close is called.

### `fn next_row(c: Conn, rows: Rows, deadline: until) -> result[bool, str]`

Reads the next row of a stream into rows (at index 0): true, or false at the end (the connection is free again).

### `fn stream_close(c: Conn, rows: Rows, deadline: until) -> result[bool, str]`

Ends a stream early: the remaining rows are read and dropped (MySQL has no way to stop a result part way).

### `fn col(rows: Rows, name: str) -> int`

The index of the column called name; panics if there is none (the query and the code reading it disagree).

### `fn is_null(rows: Rows, r: int, c: int) -> bool`

### `fn get_text(rows: Rows, r: int, c: int) -> str`

Any column as text (a binary column's bytes as they are).

### `fn get_int(rows: Rows, r: int, c: int) -> int`

The integer types, YEAR, BIT up to 64 bits, and a DECIMAL that is a whole number.

### `fn get_float(rows: Rows, r: int, c: int) -> float`

### `fn get_bool(rows: Rows, r: int, c: int) -> bool`

BOOL / tinyint(1), and any integer: true when not 0.

### `fn get_bytes(rows: Rows, r: int, c: int) -> bytes`

### `fn get_time(rows: Rows, r: int, c: int) -> result[timez.Time, str]`

A DATETIME, TIMESTAMP or DATE cell as an instant, read as UTC.

### `fn get_decimal(rows: Rows, r: int, c: int) -> result[decimal.Decimal, str]`

The exact value of a DECIMAL or integer cell, at the column's scale.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
