# PRD: General HTTP/2 response trailers

Status: implemented on `feat/http2-trailers`; awaiting review.
Date: 2026-10-11

## Context

`stdlib/http2` currently writes response headers followed by flow-controlled
DATA. It closes a stream on the final DATA frame, or on initial HEADERS for an
empty response. Protocols such as gRPC carry response status in trailing
headers, so HTTP/2 needs a general response-trailer facility before a separate
package can implement that protocol. The standard library must remain unaware
of gRPC status codes, GraphQL, and protobuf.

## Behavior

- Keep `response_msg` and `respond` behavior and wire bytes unchanged.
- Add `response_trailers_msg` and `respond_trailers` accepting ordinary
  `http2.Header` values.
- Write initial HEADERS, any flow-controlled DATA, then trailing HEADERS with
  `END_HEADERS | END_STREAM`. Empty bodies still produce both header blocks.
- Keep trailer frame bytes in the existing writer message without expanding
  the public `WMsg` struct. The writer splits the two header blocks and stores
  the trailer frame with its queued response; body bytes are not duplicated.
- Keep each response's frames serialized by the existing single writer task.
  A malformed internal trailer-message boundary sends GOAWAY with
  `INTERNAL_ERROR` and terminates the writer.

## Protocol boundary approved with this work

Keep complete gRPC and GraphQL implementations outside the compiler and
standard library. A standalone `grpc` source package and separate
`protoc-gen-slang` tool will own framing, status mapping, protobuf codecs, and
generated services; v1 targets unary calls over TLS+ALPN h2 and h2c tests.
GraphQL will be a standalone schema-first SDL package with generated ordinary
slang types and named resolvers. slang's HTTP/2 API may grow only general
transport primitives needed by independent applications, such as client
streams and trailers.

## Validation

- `tests/http2_trailers` checks both non-empty and empty response bodies and
  decodes the initial/trailing HEADERS blocks.
- `tests/http2_interop` checks trailers with Go's independent `x/net/http2`
  client, including a 200 KB flow-controlled response.
- The new consumer test fails on the old compiler with
  `package 'http2' has no function 'response_trailers_msg'`.
- `make test` passes: 183 positive fixtures, 171 negative fixtures, runtime,
  preemption and GC stress checks, and the generated-C warning sweep.
- `make docs` regenerated 34 pages, 22 packages, and 638 API items.

No throughput or allocation improvement is claimed; the change adds an
opt-in response path and leaves existing `response_msg` handling unchanged.
