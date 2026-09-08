# HTTP benches — two axes

`wrk -t$(nproc) -c{50,200} -d10s --latency` against `GET /`, 200-byte
`text/plain`, `Connection: close`, no TLS. Body length must be 200 on
every probe.

Do **not** edit `main.sl`. That file is the frozen Phase E ruler
(`next-steps.md`). New numbers on it stay comparable to every prior
run. “Slang at its best” lives in `../http_opt/main.sl` (own directory
because `slangc` compiles every `.sl` in a package).

## Axes

| Axis | Work | Slang | Go | Rust | C |
|---|---|---|---|---|---|
| **Ruler** | raw HTTP/1.0 bytes, one acceptor, per-byte `fill_wire` | `http/main.sl` | — | — | — |
| **Raw-throughput** | same bytes, no HTTP parser | `http_opt/main.sl` | `http/go_raw/` (`net`) | `http/rust_raw/` (tokio `TcpListener`) | `http/main.c` |
| **Real-server** | parse + route + headers | `examples/httpd` / `stdlib/http` | `main.go` (`net/http`) | `rust/` (axum) | — |

Ruler vs Go `net/http` / Rust axum mixes axes: slang does less work and
can still lose p99/RSS. That loss is the signal; an RPS lead there is
not a win.

Raw-throughput is the fair “can slang beat Go/Rust/C at the same job?”
question. C is the apples-to-apples peer (SO_REUSEPORT, no parser).
Go raw uses one `net.Listener` and `GOMAXPROCS` accept loops (Accept is
safe). Rust raw is tokio multi-thread + one listener. Slang opt uses
`link_listen(port, 1)` once per worker because one accept loop is one
task.

Real-server is the fair “what does a service cost?” question. Not this
harness.

## What `http_opt/main.sl` changes vs `http/main.sl`

1. `c.send_bytes(resp, …)` — no output `wire`, no 285-iteration copy.
2. `link_listen(port, 1)` × `HTTP_ACCEPTORS` (SO_REUSEPORT).
3. Env only: `SLANG_PREEMPT_QUANTUM_MS`, `SLANG_PREEMPT_TICK_MS`.
   Safepoint elision, striped runq, class freelist, DONTNEED apply
   with no source changes.

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

Phase E vs Go still needs **p99 and RSS**. RPS alone is not a win.
