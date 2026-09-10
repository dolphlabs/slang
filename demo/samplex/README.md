# samplex

A small JSON REST server in one file — three routes, a browser client,
and a worker pool. About 250 lines including the embedded HTML.

```sh
cd demo/samplex
../../slangc server.sl --run           # http://localhost:8080
PORT=9000 WORKERS=128 ../../slangc server.sl --run
```

Then open <http://localhost:8080> in a browser, or use curl/Postman.

## Routes

| Method | Path              | Body                                | Returns |
|--------|-------------------|-------------------------------------|---------|
| `GET`  | `/api/tasks`      | —                                   | `200` array of tasks |
| `POST` | `/api/tasks`      | `{"title":"...", "done":false}`     | `201` the created task |
| `PUT`  | `/api/tasks/{id}` | `{"title":"...", "done":true}`      | `200` the updated task |
| `GET`  | `/`               | —                                   | `200` a browser client |

`done` is optional on input and defaults to `false`. `id` is assigned by
the server — a client cannot choose it, which is why the accepted shape
(`NewTask`) is a different struct from the stored one (`Task`).

Errors: `400` on malformed JSON or an empty title, `404` for an unknown
path or a missing id, `405` for a known path with the wrong method.

```sh
curl localhost:8080/api/tasks
curl -XPOST localhost:8080/api/tasks \
     -H 'content-type: application/json' -d '{"title":"try slang"}'
curl -XPUT localhost:8080/api/tasks/1 \
     -H 'content-type: application/json' -d '{"title":"try slang","done":true}'
```

## Why HTTP/1.1 and not HTTP/2

Browsers only speak HTTP/2 over TLS. An h2 server on a plain port is
reachable from `curl --http2-prior-knowledge` but not from the address
bar, and this is meant to be opened in a browser. For the h2 server, see
`stdlib/http2/` and the HTTP/2 section of the top-level README.

## How the concurrency works

One acceptor task feeds a bounded `chan[link]`; a fixed pool of worker
tasks drains it. Workers are green tasks on a small OS-thread pool, so
`WORKERS=128` is 128 tasks, not 128 threads — a queue plus a pool rather
than a task per connection, which avoids paying setup and teardown per
request.

Shared state needs mutual exclusion and slang has no mutex type, so a
`chan[bool]` holding exactly one token is used as one: `chan_recv` takes
the token, `chan_send` returns it, and a task that finds it gone parks
until the holder puts it back. Every read and write of the task list is
inside that lock, including the JSON encode in `GET /api/tasks` — the
list must not be mutated mid-encode.

Verified under load: 300 concurrent `POST`s at 50-way parallelism
produce exactly 300 tasks with unique, gap-free ids, and mixed
concurrent `GET`/`POST`/`PUT` traffic leaves the state consistent.
Without the lock, concurrent `next_id` reads would hand out duplicates.

## Where the pieces come from

| | |
|---|---|
| `http` | request parsing, response building, keep-alive (`stdlib/http/`) |
| `json` | `json.encode` / `json.decode` against your own structs |
| `byteutil` | `has_prefix`, for pulling `{id}` out of the path |
| `link` / `arena` / `wire` | the connection and its read/write buffers |
| `proc` | `PORT`/`WORKERS` from the environment, graceful shutdown |

Ctrl-C stops the acceptor, closes the work queue, and waits for
in-flight connections to finish before exiting.
