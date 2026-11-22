# Missing libraries

What slang needs to be a rich language for server and network programming,
written 2026-11-22 after the earlier plan (core library, money and
identity, integrations, formats, math for servers) had landed; that plan
is in this file's git history up to #596.

Work the sections in order, one item at a time: one branch and one PR to
`dev` per item, never stacked, as AGENTS.md says. Tick a box when the item
has landed on `dev` and add the PR number. Record before/after numbers for
anything on a hot path.

**Where it lives:** *stdlib* means this repo (`stdlib/` or a native
`src/codegen/pkg_*` with its runtime in `runtime/`); *package* means a
standalone repo under `slangpackages/`.

## 1. Networking primitives

`net` has TCP and Unix stream sockets only.

- [x] **UDP** (stdlib, `net`): bind, `send_to`, `recv_from` with deadlines
  on the reactor, connected UDP, and multicast join/leave. DNS, syslog,
  StatsD, game and voice servers, and later QUIC need it. PR #600 (open).
- [x] **Socket options** (stdlib, `net`): `SO_REUSEPORT` listeners (one
  accept queue per core), `TCP_NODELAY`, keepalive idle/interval/count,
  listen backlog, and `TCP_FASTOPEN` where the OS has it. PR #601 (open).
- [x] **Zero-copy file sends** (stdlib, `net`/`fs`): `sendfile` (and
  `splice` on Linux) from a file to a socket, used by `http` for static
  files. PR #602 (open).
- [x] **PROXY protocol v1/v2** (stdlib): parse the header HAProxy and AWS
  NLB put in front of a connection, so servers see the real client address. PR #606 (open).
- [ ] **DNS resolver** (stdlib): A/AAAA/CNAME lookups over UDP with TCP
  fallback, `/etc/resolv.conf` and `/etc/hosts`, a TTL cache, timeouts,
  and happy-eyeballs dialing (RFC 8305). `net.dial` resolves IPv4 only
  today, so it cannot reach an IPv6 address: this fixes that.
  Status: IPv6 dialing with happy eyeballs is in feat/net-dial-ipv6; the
  wire-protocol client with a TTL cache waits for UDP (#600) to merge.
- [ ] **Graceful restart and draining** (stdlib): hand listening sockets to
  a new process, stop accepting, and drain open connections with a
  deadline.

## 2. Resilience

- [x] **Cancellation contexts** (stdlib): a deadline and cancel signal that
  flows from a request through `httpc`, `pg`, `redis` and the other
  clients, so one timeout stops everything under it. PR #603 (open).
- [x] **Generic connection pool** (stdlib): health checks, max idle/open,
  idle and lifetime limits, fair FIFO waiting, wait-time metrics. The
  speed audit found Slang's pool-acquisition p99 above Go's on every route. PR #604 (open).
- [x] **Failure handling** (stdlib): circuit breaker, bulkhead, retry with a
  retry budget (over `rand.backoff`), token-bucket and GCRA rate limiters,
  and request hedging. PR #611 (open).
- [x] **Singleflight** (stdlib): concurrent identical calls share one
  execution, for cache stampedes. PR #612 (open).

## 3. Observability

- [x] **Prometheus metrics** (stdlib): counters, gauges and histograms with
  labels, text exposition format, histograms over `math/sketch`. PR #607 (open).
- [x] **OpenTelemetry export** (stdlib or package): OTLP over HTTP/protobuf
  for traces, metrics and logs, with W3C `traceparent` propagation in
  `http` and `httpc`. PR #608 (open).
- [ ] **Runtime stats API** (stdlib): GC cycles and pauses, heap and RSS,
  task count, reactor queue depth.
- [ ] **Profiler endpoint** (stdlib): sampled CPU profiles, allocation
  sites and task dumps, readable by standard tools.
  Status: not started. Needs a design first: sampling by signal next to
  the preemption signals, and symbolising static functions in generated C.

## 4. Compression and formats

- [ ] **zstd, brotli and lz4** (stdlib, `compress`): streaming encode and
  decode; zstd and brotli as HTTP `Content-Encoding`, lz4 for Kafka.
  Status: needs a decision. The libraries are not on the build machines;
  system dependencies or vendored sources?
- [x] **MessagePack and CBOR** (stdlib): encode and decode, structs
  included, with size limits. PR #615 (open).
- [x] **Protobuf codec** (stdlib or package): wire-format encode and decode
  outside gRPC. PR #605 (open).
- [x] **HTTP extras** (stdlib, `http`): Server-Sent Events, streaming
  multipart/form-data uploads, and range requests. PR #610 (open).
- [ ] **gRPC streaming** (package `slangpackages/grpc`): server, client and
  bidirectional streams; the package is unary only.
  Status: in progress on feat/grpc-streaming in the grpc repo; left alone here.
- [ ] **HTTP/3 and QUIC** (stdlib): after UDP.
  Status: not started; after UDP.

## 5. Identity and security

- [ ] **OAuth2 and OpenID Connect client** (stdlib or package):
  authorization code with PKCE, client credentials, refresh, discovery,
  ID-token checks against JWKS.
- [ ] **ACME** (stdlib): automatic certificates from Let's Encrypt with
  renewal, served through `tls_ctx_add_sni`.
- [x] **TOTP and HOTP** (stdlib): RFC 6238/4226 codes and checks with skew. PR #617 (open).
- [ ] **WebAuthn / passkeys** (package): registration and assertion.
  Status: waits for the CBOR PR (feat/msgpack-cbor) to merge.
- [ ] **Envelope encryption** (stdlib, `crypto`): AES-GCM data keys wrapped
  by a key-encryption key, with key ids for rotation.

## 6. Data and integrations

- [x] **SMTP client and MIME** (stdlib): STARTTLS, AUTH, multipart mail. PR #609 (open).
- [ ] **ClickHouse client** (package).
  Status: needs a new slangpackages repository; not created without approval.
- [ ] **OpenSearch / Elasticsearch client** (package).
  Status: needs a new slangpackages repository; not created without approval.
- [ ] **Cassandra / Scylla client** (package).
  Status: needs a new slangpackages repository; not created without approval.
- [ ] **memcached client** (stdlib or package).
- [ ] **etcd and Consul** (package): key/value, watches, service discovery.
  Status: needs a new slangpackages repository; not created without approval.

## 7. Distributed systems

- [ ] **Leases and leader election** (stdlib): over Redis and Postgres
  advisory locks.
- [x] **Outbox and idempotency keys** (stdlib): transactional outbox and a
  store for idempotent handlers. PR #616 (open).
- [x] **CRDTs** (stdlib): G-counter, PN-counter, OR-set, LWW-map, mergeable
  like `math/sketch`. PR #613 (open).
- [ ] **Client-side load balancing** (stdlib): pick a backend by
  consistent hash (`math/shard`), least-loaded or power of two choices.

## Already covered

So these are not re-proposed: HTTP/1.1 server and client, HTTP/2 (server
and multiplexed client), WebSocket server and client, TLS (mTLS, SNI,
ALPN), JSON, CSV, XML, YAML, TOML, templates with auto-escaping, Postgres,
MySQL, SQLite, Redis, MongoDB, NATS, Kafka, AMQP, SQS, SNS, S3, GCS,
GraphQL, unary gRPC, JWT and JWKS, Argon2id, crypto (SHA-2, HMAC, AEAD,
signatures), x509, uuid, decimal, regex, gzip/deflate, tar, zip, `time`
and `timez` (zones, cron), logging, flags, filesystem, environment and
process, Unicode, `sort`, `rand`, `math` with `stats`, `numtheory`, `vec`,
`sketch`, `shard`, `optimize`, `interp`, `geo`, `finance` and `big`, and
zokor's web framework (routing, validation, auth, rate limiting, jobs,
migrations, metrics, tracing, OpenAPI).
