# Benchmark specification

The contract every implementation in `bench/` satisfies. A number is only
meaningful if every language did **the same work, verified**: each workload
below has a conformance check that runs before anything is measured, and an
implementation that fails it is reported as failed, not measured.

Languages: **slang, Go, Rust, C, C#, Java, Python, Bun, Node.js.**

Two tiers:

| Tier | Workload | What it measures |
|---|---|---|
| light | `http-static` | raw connection handling: accept, read, write 200 bytes, close |
| light | `compute` | concurrent CPU + small allocations across many tasks |
| heavy | `api` | a production-shaped JSON service over Postgres: point reads, pagination, aggregates, writes, and a large CPU-bound JSON body |
| heavy | `batch` | a big-data job: stream a multi-GB file, parse, group by millions of keys, top-K |

Each implementation is the **fastest and leanest version its ecosystem
supports in production**: release builds, the fastest mainstream server,
driver and JSON library, allocator and GC settings a performance-minded team
would ship. Not micro-benchmark tricks that nobody would deploy. The chosen
stack for each language is fixed in the tables below, so a result can be
traced to exactly what ran.

---

## Rules that apply to every workload

1. **Same work.** Identical SQL (given verbatim below), identical response
   contracts, identical dataset. Languages differ only in runtime, server,
   driver, JSON and concurrency model — which is the point.
2. **Release builds only.** Flags per language are in `bench/suite/langs.sh`,
   the single source of truth for how everything is built and started.
3. **Pinned versions.** `bench/suite/setup_host.sh` installs exact toolchain
   versions; library versions are pinned in each lockfile or manifest.
4. **Configuration by environment only:** `PORT`, `DATABASE_URL`,
   `DB_POOL_TOTAL`, `WORKERS`. No per-run code edits.
5. **Use every core the harness gives the server.** `WORKERS` is the number
   of cores allotted (the harness pins the server with `taskset`). Runtimes
   that scale by process (Python, Bun, Node) start `WORKERS` processes on
   one port with `SO_REUSEPORT`; runtimes that scale by thread use that many.
6. **One database pool budget.** `DB_POOL_TOTAL` connections across the whole
   server. A multi-process runtime gives each process
   `ceil(DB_POOL_TOTAL / WORKERS)`.
7. **Conformance before measurement.** `bench/suite/lib/conformance.py`
   (api) and a SHA-256 of the output (batch, compute) gate every run.
8. **Order alternates.** Languages run in a rotated order each round, so no
   language is always first (cold page cache) or last (warm, throttled).
9. **Nothing else on the machine.** See `bench/CURSOR.md` for topology.

---

## light / `http-static`

Existing workload, unchanged, so new runs stay comparable with
`bench/RESULTS.md`. `GET /` → exactly:

```
HTTP/1.0 200 OK\r\n
Content-Type: text/plain\r\n
Content-Length: 200\r\n
Connection: close\r\n
\r\n
0123456789abcdef × 12, then 01234567   (200 bytes)
```

Read the request, write the response, close. Port from `HTTP_PORT`.
Load: `wrk -t$T -c{50,200} -d30s --latency http://127.0.0.1:$PORT/`.

## light / `compute`

Existing workload. Environment `CC_TASKS`, `CC_WORK`, `CC_ALLOC`. Spawn
`CC_TASKS` concurrent tasks; each counts primes in `[0, CC_WORK)` by trial
division (the exact loop in `bench/compute/main.go`, no early exit) and
builds a list and a string-keyed map of `CC_ALLOC` entries, summing both.
Print one line:

```
RESULT tasks=<n> work_n=<n> alloc_n=<n> wall_ms=<n> total_primes=<n> total_alloc_sum=<n> tasks_per_sec=<n>
```

`total_primes` and `total_alloc_sum` are checked against the Go output.

---

## heavy / `api`

An HTTP/1.1 JSON service. **Keep-alive by default**; honour
`Connection: close`. Every response carries `Content-Type: application/json`
and `Content-Length` (no chunked responses). Request bodies arrive with
`Content-Length`. Any other method/path → `404 {"error":"not found"}`.
A malformed request (bad id, bad limit, bad body) → `400 {"error":"bad request"}`.
JSON is compared **parsed** by the conformance check, so key order and
whitespace are free; field names, types and array order are not.

### Dataset

Created by `bench/suite/db/schema.sql` and `seed.sql`, deterministic (no
`random()`), scale set by `USERS` (default 1,000,000) and `ORDERS` (default
20,000,000 — about 3.5 GB with indexes).

```sql
users(id bigint pk, email text, name text, country char(2), created_at timestamptz)
orders(id bigint pk (identity), user_id bigint, sku text, qty int,
       price_cents bigint, status text, created_at timestamptz)
index orders_user_created on orders(user_id, created_at desc, id desc)
```

Timestamps are formatted **in SQL**, so no language pays for date
formatting and every response is byte-identical:
`to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')`.
Below, that expression is written `TS(created_at)`.

### Endpoints

**`GET /health`** → `200 {"ok":true}`. No database. Used for readiness.

**`GET /api/users/{id}`** — point read.

```sql
SELECT id, email, name, country, TS(created_at) FROM users WHERE id = $1
```

`200 {"id":1,"email":"user1@example.com","name":"User 1","country":"NG","created_at":"2020-01-01T00:00:37Z"}`
or `404 {"error":"not found"}`. `{id}` must be a positive integer, else 400.

**`GET /api/users/{id}/orders?limit={n}`** — pagination, many rows.
`limit` defaults to 20; must be 1..100, else 400.

```sql
SELECT id, sku, qty, price_cents, status, TS(created_at)
FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2
```

`200 {"user_id":7,"orders":[{"id":..,"sku":"SKU-01234","qty":3,"price_cents":1999,"status":"paid","created_at":"..."}, ...]}`
(an unknown user yields `"orders":[]`, not 404).

**`GET /api/users/{id}/summary`** — aggregate.

```sql
SELECT status, count(*), coalesce(sum(qty * price_cents), 0)
FROM orders WHERE user_id = $1 GROUP BY status
```

`200 {"user_id":7,"order_count":21,"total_cents":123456,"by_status":{"cancelled":4,"delivered":5,"paid":3,"pending":6,"shipped":3}}`
— all five statuses always present, zero when absent; `order_count` and
`total_cents` are the sums over the groups.

**`POST /api/orders`** — write. Body
`{"user_id":7,"sku":"SKU-00042","qty":2,"price_cents":1999}`.
Valid when `user_id ≥ 1`, `sku` is 1..32 characters, `qty` is 1..1000 and
`price_cents` is 1..1,000,000,000; otherwise 400.

```sql
INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at)
VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id
```

`201 {"id":20000001,"status":"pending"}`. The harness deletes rows above the
seeded maximum id between rounds.

**`POST /api/quote`** — CPU and JSON heavy, no database. Body (the harness
sends ~2,000 items, ~110 KB):

```json
{"region":"EU","items":[{"sku":"SKU-00001","qty":3,"price_cents":1999}, ...]}
```

For each line, all integer arithmetic (64-bit, truncating division):

```
gross    = qty * price_cents
discount = gross * 500 / 10000   if qty >= 10, else 0
net      = gross - discount
tax      = net * rate_bp / 10000
```

`rate_bp` by region: `US 725, CA 1300, UK 2000, EU 2000, DE 1900, FR 2000,
JP 1000, IN 1800, BR 1700, NG 750, AU 1000`; any other region → 400.
Empty `items` or an item with `qty < 1` or `price_cents < 0` → 400.

```
200 {"region":"EU","lines":2000,"subtotal_cents":Σgross,"discount_cents":Σdiscount,
     "tax_cents":Σtax,"total_cents":Σnet+Σtax,
     "top_skus":["SKU-..", ...]}
```

`top_skus`: the skus of the 5 lines with the largest `net`, ties broken by
sku ascending, then by position in `items` (a sku may repeat).

### Load

`wrk` (max throughput) and `wrk2` (fixed rate, corrected for coordinated
omission), both with Lua scripts in `bench/suite/lib/`:

| Scenario | Script | Mix |
|---|---|---|
| `mix` | `mix.lua` | 50% user by id · 15% orders limit 50 · 10% summary · 10% create order · 15% quote |
| `point` | `point.lua` | 100% user by id (database-bound) |
| `quote` | `quote.lua` | 100% quote (CPU/JSON-bound, no database) |

Ids are uniform over the seeded range from a fixed seed; quote bodies are
pre-generated files (`bench/suite/data/quote_*.json`).

Per scenario: warm-up 15 s, then throughput at connections `64` and `512`
for `API_DUR` (default 60 s) each, then `wrk2` at fixed rates
(`API_RATES`, default `2000 10000`) for latency. Recorded: requests/s,
p50/p90/p99/p99.9 latency, non-2xx and socket errors, peak RSS and average
CPU cores of the server's whole process tree, and the database's CPU.

---

## heavy / `batch`

Stream a large CSV and aggregate it. `argv[1]` is the path; print the report
to stdout and nothing else. All cores may be used (threads, processes,
`mmap`, positional reads — whatever the ecosystem does best).

### Input

Generated by `bench/suite/data/gen_batch.c` (deterministic):
`BATCH_ROWS` rows (default 100,000,000, ≈ 4 GB), `BATCH_USERS` distinct
users (default 5,000,000). No header. Each line:

```
<ts>,<user_id>,<sku>,<qty>,<price_cents>,<region>\n
1640995200,4821,SKU-04821,3,1999,NG
```

`ts` is a 10-digit unix time, `user_id` 1..BATCH_USERS, `sku` `SKU-` + 5
digits, `qty` 1..20, `price_cents` 50..50049, `region` one of 20 codes:
`AR AU BR CA DE EG ES FR IN IT JP KR MX NG NL PL SE UK US ZA`.

### Output

`revenue = Σ qty * price_cents` (64-bit). Exactly, `\n`-terminated:

```
rows=<total rows>
region=<CODE> count=<rows> qty=<Σqty> revenue=<Σrevenue>          × 20, CODE ascending
top_user rank=<1..100> user_id=<id> revenue=<Σrevenue>             × 100, revenue desc, user_id asc
top_sku rank=<1..10> sku=<SKU-nnnnn> revenue=<Σrevenue>            × 10, revenue desc, sku asc
```

**Keys are opaque.** Aggregate users and skus in hash maps (any hash map,
including a hand-written open-addressing one). Do not index an array by
`user_id` or by the digits of a sku: the generator happens to produce dense
ids, real data does not, and memory for millions of keys is part of what
this measures.

Checked by SHA-256 against the reference output for the same `BATCH_ROWS`
and `BATCH_USERS`. Recorded: wall time, peak RSS of the process tree, CPU
time.

---

## Implementations

| Language | api stack | batch approach |
|---|---|---|
| slang | `stdlib/http` + `stdlib/pg` pool + `json`; `spawn` per connection | `fs.pread` chunks across tasks, merged maps |
| Go | `fasthttp`, `pgx/v5` pool, `goccy/go-json` | `mmap`, goroutine per chunk, custom parser |
| Rust | `axum` 0.8 on `tokio`, `deadpool-postgres`/`tokio-postgres`, `serde_json`, `mimalloc` | `memmap2`, `std::thread::scope`, `ahash` maps |
| C | epoll worker threads, `libpq` connection per worker, hand-written HTTP/JSON | `mmap`, `pthread` per core, open-addressing tables |
| C# | ASP.NET Core Kestrel minimal API, `Npgsql` data source, `System.Text.Json` source-generated, Server GC | `MemoryMappedFile`, `Parallel.For` over chunks |
| Java | Vert.x 4 web + reactive `vertx-pg-client` | `FileChannel` mapped chunks, platform thread per core |
| Python | `uvloop` + `httptools` protocol server, `asyncpg`, `orjson`; one process per core | `multiprocessing` over byte ranges, `mmap` |
| Bun | `Bun.serve` + built-in `Bun.SQL`; one process per core (`reusePort`) | `Bun.file` byte ranges across `Worker`s |
| Node | `node:http` + `postgres` (porsager); one process per core | `fs.read` byte ranges across `worker_threads` |
