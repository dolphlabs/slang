# Missing libraries

What slang's packages lack for building backend services, found 2026-10-27
by checking the builtins (`src/codegen/core.c`), the standard library
(`stdlib/`, `src/codegen/pkg_*`), the separate packages (`slangpackages/`),
zokor, and what the `say` and `sendbyte` services had to write by hand.

Tick a box when the package (or the item within it) has landed on `dev`, and
add the PR number. Each item is its own branch and PR, as AGENTS.md says.

**Where it lives:** *stdlib* means a package in this repo (`stdlib/` or a
native `src/codegen/pkg_*`); *package* means a standalone repo like
`slangpackages/jwt`.

## 1. Core library

The basics nearly every program needs. None of these exist as a builtin or in
any package.

- [x] **`sort`** (stdlib): sort lists of ints, floats and strings, and lists
  of structs by a key function; stable sort; binary search on sorted lists.
  PR #468.
- [x] **`math`** (stdlib): `abs`, `min`, `max`, `clamp`, `floor`, `ceil`,
  `round`, `sqrt`, `pow`, `log`, `exp`, trigonometry, `is_nan`/`is_inf`, and
  overflow-checked integer helpers (`checked_add`, `checked_mul`, ...).
  Evidence: `say` wrote its own `checked_mul` for money
  (`say/src/ledger/domain/money.sl`). Planned in full in `math-plan.md`.
  PR #477 (`math`), #481 (`math/stats`, `math/numtheory`), #483, #485.
  Still to build, per `math-plan.md` phases 3 to 5:
  - [ ] `math/complex`
  - [ ] `math/linalg` (fixed-size)
  - [ ] `math/big`
- [x] **`rand`** (stdlib): a fast, non-cryptographic random number generator
  with an explicit seed, so tests stay deterministic: ints in a range,
  floats, shuffle, pick, and jitter for retry backoff. `crypto.rand` stays
  the source for secrets. PR #506.
- [x] **`uuid`** (stdlib): v4 (random) and v7 (time-ordered, good as a
  database key), parse, validate, format. Evidence: `say` builds UUIDs by
  hand in five places (`platform/app/app.sl`, `markets/service/service.sl`,
  `exchange/domain/types.sl`, `ledger/domain/money.sl`, a test helper), and
  the main one always forces the variant digit to `a`. PR #505.
- [ ] **Unicode / UTF-8** (stdlib, `strings` or its own package): iterate a
  string by character, validate UTF-8, count characters (not bytes),
  case-fold. Needed for username rules and text length limits.

## 2. Money and identity

What `say` (the exchange) needs and currently hand-rolls.

- [ ] **`decimal`** (stdlib): fixed-point decimal arithmetic for money: parse
  and format, add, subtract, multiply and divide with an explicit scale and
  rounding mode, compare, overflow as an error rather than a wrap. JSON and
  Postgres `numeric` round-trips. Evidence: `say` writes its own decimal
  encoding (`exchange/domain/bytes.sl`).
- [ ] **`crypto` additions** (stdlib). It has SHA-256/HMAC-SHA256, SHA-1,
  MD5, PBKDF2, Argon2id and RSA verify (SHA-256) only. Missing:
  - [ ] authenticated encryption: AES-256-GCM and ChaCha20-Poly1305, for
    data at rest and encrypted cookies (zokor's cookies are signed, not
    encrypted)
  - [ ] Ed25519 sign and verify
  - [ ] ECDSA P-256 sign and verify
  - [ ] RSA sign (PKCS#1 v1.5 and PSS, SHA-256)
  - [ ] SHA-512 and HMAC-SHA512
  - [ ] HKDF
  - [ ] constant-time comparison as a public function
- [ ] **`jwt` algorithms and JWKS** (package `slangpackages/jwt`). It
  supports HS256 only. Missing:
  - [ ] RS256 (verify and sign)
  - [ ] ES256 (needs ECDSA above)
  - [ ] EdDSA (needs Ed25519 above)
  - [ ] a JWKS client: fetch, cache by `kid`, refresh on an unknown `kid`,
    rate-limited (evidence: `say/src/accounts/service/google.sl` hand-writes
    all of this for Google sign-in)
  - [ ] OIDC ID-token verification helper (issuer, audience, expiry, nonce)

## 3. Integrations

Common backend needs with no package today.

- [ ] **Message broker client** (package). None exists; only Redis streams.
  Pick one to start: NATS (simplest protocol), Kafka, or RabbitMQ (AMQP
  0-9-1). AGENTS.md's architecture rules lean on events and queues for
  decoupling.
- [ ] **S3-compatible object storage** (package): put, get, delete, list,
  multipart upload, presigned URLs, with AWS SigV4 signing. Works against
  S3, R2, MinIO. zokor handles uploads but has nowhere durable to put them.
- [ ] **Templating with auto-escaping** (stdlib): HTML templates that escape
  by context, plus plain-text templates. Evidence: `say` has an email
  `templates/` folder and no safe engine to render it with.
- [ ] **WebSocket client** (stdlib, beside `httpc`): dial, TLS, ping/pong,
  close handshake, size limits. zokor has the server side only.
- [ ] **MySQL / MariaDB driver** (stdlib or package): only Postgres, SQLite
  and Mongo exist.

## 4. Smaller formats and protocols

- [ ] **CSV** (stdlib): RFC 4180 read and write, streaming, quoted fields,
  row and field size limits.
- [ ] **base32** (stdlib, in `encoding`): RFC 4648, for TOTP secrets and
  readable codes.
- [ ] **gRPC streaming** (package `slangpackages/grpc`): server, client and
  bidirectional streams; the package is unary only.

## Already covered

For reference, so these are not re-proposed: HTTP/1.1 server and client,
HTTP/2 (server and multiplexed client), TLS, JSON, Postgres, Redis, SQLite,
MongoDB, regex, gzip/deflate, `time` and `timez` (zones, cron), logging,
command-line flags, filesystem, environment and process, terminal I/O,
GraphQL, unary gRPC, JWT (HS256), Argon2id, and zokor's web framework
(routing, validation, auth, rate limiting, WebSocket server, jobs,
migrations, metrics, tracing, OpenAPI).
