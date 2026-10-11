# PRD: Protocol Packages and Lean Dependency Downloads

Status: architecture approved; package exclusions implemented on
`feat/package-download-excludes`, with the full test suite passing.
Date: 2026-10-11

## Problem

Slang has HTTP/2 transport and TLS support, but no gRPC or GraphQL implementation. Putting complete protocol stacks, schema parsers, and generators in the compiler or every generated binary would enlarge the language distribution and increase maintenance for features many services do not need. Slang applications also fetch and retain full package repositories even when a package ships large non-runtime directories such as `bench/`, `examples/`, and `tests/`.

The goal is to provide production-quality gRPC and GraphQL for Slang and Zokor while keeping the compiler/runtime small, and let package authors publish a smaller dependency checkout without weakening lockfile verification.

## Current implementation facts

- `stdlib/http2/` is a Slang-source HTTP/2 server stack with frame parsing, HPACK, TLS transport, concurrency, flow control, deadlines, and request-body limits.
- Its public API is server-oriented: it exposes `read_request`, `writer_task`, and `response_msg`; it has no client connection API or trailer-response API today.
- `stdlib/http`, `net`, `time`, and JSON support provide reusable lower-level building blocks. Slang has no reflection or closures; generated code and named function values fit its model.
- Zokor's `src/` package is an HTTP/1 server/router with generic app state and named function handlers. Its repository already keeps `examples/` and `docs/` outside the imported package and asks protocol parsers to be sans-I/O and caller-limited.
- `slangc get` shallow-clones each pinned repository into a content-addressed cache. The lock hash currently covers every regular file in the checkout. `dir <subdir>` changes what compiles, but does not reduce transferred or cached files.

## Product principles

1. The compiler and generated runtime do not gain GraphQL, protobuf, or gRPC-specific machinery.
2. Slang's standard library owns only general-purpose primitives that have independent value to non-gRPC and non-GraphQL users.
3. Protocol packages are separate repositories and are fetched only by applications that import them. Zokor integration is an optional adapter, not a dependency of the protocol package.
4. Wire parsers are bounded, fuzzed, and sans-I/O where practical. Limits are explicit and caller-configurable. Allocation and request-path costs are measured.
5. Exclusions affect only package distribution/cache contents; they never silently change application source semantics. Lock verification covers all included files.

## Proposed architecture

### Slang core / standard library

Keep the compiler, runtime, `net`, `http`, `http2`, `json`, `time`, and generic byte utilities. Add a feature to `http2` only when it expresses a reusable HTTP/2 capability needed by protocols and ordinary servers. The likely reusable gaps are client-side HTTP/2 stream/connection support and response trailers; gRPC-specific status mapping and protobuf handling do not belong here. TLS ALPN changes, if required, must remain general-purpose TLS APIs.

No GraphQL or protobuf syntax, reflection, generated-service dispatch, or protocol-specific compiler subcommand is proposed.

### gRPC package

Create a standalone `grpc` Slang package and a separate `protoc-gen-slang` generator. The generator reads `.proto` descriptors and emits ordinary Slang structs plus bounded protobuf codecs and service stubs; it does not extend the slang parser. The package owns gRPC message framing, status/deadline mapping, and typed client/server glue. It may depend on general HTTP/2 primitives from slang.

Recommended v1: unary client and server calls over HTTP/2 with TLS+ALPN `h2` and optional h2c for local tests; enforce configurable message-size, metadata, and concurrent-stream limits; propagate `grpc-timeout` to `until`; report errors in standard gRPC trailers. Add streaming only after unary interoperability and load tests pass. The package must not maintain a second HTTP/2 connection engine if general client support can be added once to `http2`.

A Zokor adapter remains optional. Since Zokor currently serves HTTP/1 only, gRPC may initially use a dedicated HTTP/2 listener and explicit app state rather than being forced through the HTTP/1 router.

### GraphQL package

Create a standalone `graphql` Slang package and a separate schema generator. Use schema-first SDL and generate ordinary Slang types, schema metadata, and named resolver signatures; do not inspect Slang types at runtime. The package owns the bounded query parser, validation, variable coercion, and execution. Resolver functions are named values with explicit context/state; no closure support is needed.

Recommended v1: queries and mutations, variables, named operations, and fragments; no subscriptions or runtime introspection initially. Enforce configurable request bytes, depth, field count, aliases, and execution cost before resolving. Provide explicit batch-resolver support in v1 so nested relations do not default to one database query per result. Compare equivalent typed workloads for latency, allocation, and RSS.

A separate `graphql-zokor` adapter maps a Zokor request context to GraphQL execution and returns the GraphQL protocol response. It remains optional and must preserve GraphQL's response envelope while using Zokor for routing, app state, and middleware.

### Package exclusions

Recommended publisher-owned manifest syntax: repeatable top-level lines in a package's `slang.project`, for example:

```text
name mongo
version 0.1.0
exclude bench
exclude examples
exclude tests
```

Paths are literal repository-relative directories, not globs. Reject absolute paths, `.`/`..`, empty segments, and backslashes. The root manifest and any explicitly selected `dir` package must remain available. Excluded paths do not participate in the cached source tree or its lock hash.

To omit transfer as well as cached files, `slangc get` should use a shallow partial clone with sparse checkout: fetch root metadata first, parse the package's exclusions, then fetch/check out all remaining paths. If the remote Git server does not support partial clones, fall back to a full shallow clone and prune excluded paths before hashing and storing. In either case, the lock hashes the exact included tree and compiler builds continue to reject a missing cache or hash mismatch. A test must prove the fallback behavior and that a changed included file fails verification.

This syntax is package-author metadata, so consuming projects need no duplicate path lists. Existing packages with no `exclude` lines retain today's full-tree behavior.

## Scope and delivery order

1. Approve this architecture and finalize the `exclude` manifest semantics.
2. Implement package exclusion and partial-clone/fallback behavior in slang, as its own PR from current `dev`.
3. Land the reusable HTTP/2 API changes shown necessary by gRPC interoperability as a separate slang PR, with HTTP/2 client/server tests and no gRPC policy in the API.
4. Build and measure the standalone gRPC package/generator; start with unary interoperability against Go.
5. Build and measure the standalone GraphQL package/generator; add Zokor adapter and N+1 batch workload.

Each runtime package PR includes hostile-input tests, external interoperability, performance/allocation/RSS evidence, and package documentation. Package repositories are not dependencies of the slang compiler.

## Success criteria

- A minimal Slang install has no new gRPC, GraphQL, or protobuf runtime code.
- An app that imports neither package builds and runs exactly as before.
- Generated package APIs compile with ordinary Slang; no reflection or compiler language changes are required.
- Unary gRPC passes Go interoperability over TLS+ALPN and h2c, with correct statuses, trailers, deadlines, and limits.
- GraphQL passes the chosen spec-conformance suite, rejects over-budget queries before resolver work, and demonstrates bounded allocations and no accidental N+1 in the batch case.
- Excluded package directories are absent from the cache; partial-clone remotes avoid fetching excluded blobs, and fallback remotes still produce a verified included tree.

## Owner decisions (approved 2026-10-11)

1. Protocol/package split and the recommended v1 scope above: approved.
   Generators and protocol implementations are standalone; no compiler
   protocol syntax or runtime support is planned. Reusable HTTP/2 primitives
   may be added to slang after interoperability demonstrates the need.
2. Package-owned `exclude <dir>` lines with sparse partial-clone plus shallow
   full-clone fallback: approved.

## Package-exclusion implementation and evidence

The `feat/package-download-excludes` change adds repeatable package-owned
`exclude` directives, validates them as literal relative directory paths, and
uses sparse checkout to omit excluded paths before hashing and caching. It
first requests a blob-filtered shallow clone for remote URLs. If Git rejects
that filter, slang removes the incomplete checkout and retries as a shallow
sparse clone without filtering; unsupported filters that Git merely ignores
also remain safe because excluded paths are omitted before the cache hash is
computed. The package manifest stays checked out for transitive dependency
resolution, and a consumer cannot select a package `dir` under an excluded
path. Cache entries omit `.git` in both paths.

The integration tests exercise a filtered remote, a forced filter rejection,
transitive package metadata, source compilation, lock-hash mismatch after an
included-file edit, traversal rejection, selection of an excluded `dir`, and
a symlinked package manifest. The old compiler failed the new manifest case
with `unknown field 'exclude'`.

On a synthetic repository with an 8 MiB random blob under an excluded
`bench/` directory, a shallow full checkout occupied 16,500 KiB. A blob-filter
sparse checkout occupied 152 KiB with `.git` retained and 8 KiB after the
cache removed Git metadata. These are local disk/object-size measurements,
not a packet capture; the filtered path avoids requesting the excluded blob
when the remote honors Git's partial-clone filter.

Validation: `make test` passes, including 182 positive Slang fixtures, 171
negative fixtures, package integration checks, GC/preemption stress, and the
generated-C warning sweep (`PASS generated C is warning-free`). `make docs`
was run after the README change and regenerated the tracked site outputs.
