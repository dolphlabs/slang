# HTTP benches — three axes, one rule

`wrk -t$(nproc) -c{50,200} -d10s --latency` against `GET /`, 200-byte
`text/plain`, `Connection: close`, no TLS. Body length must be 200 on
every probe.

Do **not** edit `main.sl`. That file is the frozen Phase E ruler
(`next-steps.md`). New numbers on it stay comparable to every prior
run. "Slang at its best" lives in `../http_opt/main.sl` (own directory
because `slangc` compiles every `.sl` in a package).

## Axes

An RPS lead on one axis says nothing about the others. Every claim
names its axis. Mixing axes (e.g. ruler slang vs `net/http` Go) is how
a real p99/RSS loss hides behind a fake RPS win.

| Axis | Work | Slang | Go | Rust | C | Win condition |
|---|---|---|---|---|---|---|
| **Ruler** | raw HTTP/1.0 bytes, one acceptor, per-byte `fill_wire` | `http/main.sl` | — | — | — | comparability only, never a win claim |
| **Raw-throughput** | same bytes, no HTTP parser | `http_opt/main.sl` | `http/go_raw/` (`net`) | `http/rust_raw/` (tokio `TcpListener`) | `http/main.c` | p99 **and** RSS vs Go; RPS alone is not a win |
| **Real-server** | parse + route + headers | `examples/httpd` / `stdlib/http` | `main.go` (`net/http`) | `rust/` (axum) | — | p99 **and** RSS vs Go; RPS alone is not a win |

Ruler vs Go `net/http` / Rust axum mixes axes: slang does less work and
can still lose p99/RSS. That loss is the signal; an RPS lead there is
not a win.

Raw-throughput is the fair "can slang beat Go/Rust/C at the same job?"
question. C is the apples-to-apples peer (SO_REUSEPORT, no parser).
Go raw uses one `net.Listener` and `GOMAXPROCS` accept loops (Accept is
safe). Rust raw is tokio multi-thread + one listener. Slang opt uses
`link_listen(port, 1)` once per worker because one accept loop is one
task.

Real-server is the fair "what does a service cost?" question. Slang
goes through `stdlib/http` `parse` + `read`/`write`; Go stays on
`net/http`; Rust stays on axum. No numbers claimed on this axis yet —
that harness is future work, not this one.

## What `http_opt/main.sl` changes vs `http/main.sl`

1. `c.send_static(b"…", …)` — zero GC allocs on send: no output
   `wire`, no 285-iteration copy, no `sl_bytes_new` header + payload.
   (Was `send_bytes(resp, …)` before item 9; `send_static` is the same
   bytes with the response-literal allocs removed.)
2. `link_listen(port, 1)` × `HTTP_ACCEPTORS` (SO_REUSEPORT).
3. Env only: `SLANG_PREEMPT_QUANTUM_MS`, `SLANG_PREEMPT_TICK_MS`.
   Safepoint elision, striped runq, class freelist, DONTNEED, adaptive
   threshold apply with no source changes.

Recv still uses a 4 KB arena + 2 KB wire so the request is actually
read before the response, same as C.

## Remeasure (raw axis)

```
make slangc
HTTP_ROUNDS=3 HTTP_DUR=10s HTTP_CONCS="50 200" ./bench/run_http_opt.sh
```

The script sets:

| env | default | why |
|---|---|---|
| `HTTP_ACCEPTORS` | `nproc` | one reuseport listener per worker |
| `SLANG_PREEMPT_QUANTUM_MS` | `50` | IO parks already yield; fewer SIGUSR1 hits |
| `SLANG_PREEMPT_TICK_MS` | `10` | same |

Ports: slang_opt 18190, go_raw 18191, c 18192, rust_raw 18193.
Output: `/tmp/slang_http_opt`.

Frozen-ruler remasure stays `./bench/run_http.sh` (ports 18180–18186,
`/tmp/slang_phase_e_http`).

Phase E vs Go still needs **p99 and RSS** on the claimed axis. RPS
alone is not a win, on any axis.
