# trace

> Package trace.

Distributed tracing: spans with W3C trace context propagation
(`traceparent`), exported to an OpenTelemetry collector over OTLP/HTTP
with JSON bodies.

```slang
import "trace";

let t = trace.tracer("checkout", "http://otel-collector:4318");

// a request came in: continue the caller's trace if it sent one
let parent = trace.parse_traceparent(incoming_traceparent);
let span = trace.start(t, "POST /orders", parent);
trace.set_str(span, "http.route", "/orders");
let db = trace.child(span, "insert order");
trace.end(db);
outgoing_headers["traceparent"] = trace.traceparent(span);   // to the next service
trace.end(span);
```

- `start(t, name, parent)` starts a span: a child of a caller's context
  (from `parse_traceparent`, which refuses malformed values per the W3C
  spec) or the root of a new trace. `child(span, name)` nests one.
- `set_str`, `set_int`, `set_float`, `set_bool`, `set_kind`, `set_error`
  and `set_ok` describe it; `end` queues it for export.
- Ended spans are sent in batches by a background task: when
  `max_batch` are queued, and every `flush_ns` otherwise. The queue is
  bounded by `max_queue`; spans past it, or lost in a failed send, are
  counted in `counts(t).dropped`, so a dead collector costs bounded
  memory. `flush(t, deadline)` sends now.
- `sample_ratio` decides new traces; a continued trace follows the
  caller's sampled flag. An unsampled span records nothing.
- A tracer with endpoint `""` sends nothing and keeps spans for
  `drain(t)`, for tests.

## API

### `struct Options`

### `fn options() -> Options`

### `struct SpanContext`

A span's place in a trace, as traceparent carries it.

### `struct Attr`

### `gc struct Span`

### `gc struct Tracer`

### `let KIND_INTERNAL = 1;`

### `let KIND_SERVER = 2;`

### `let KIND_CLIENT = 3;`

### `let KIND_PRODUCER = 4;`

### `let KIND_CONSUMER = 5;`

### `fn tracer(service: str, endpoint: str) -> Tracer`

A tracer for one service. endpoint is the collector's base URL (spans go to endpoint + "/v1/traces"); "" exports nothing and keeps ended spans for drain(), for tests.

### `fn tracer_with(service: str, endpoint: str, o: Options) -> Tracer`

### `fn start(t: Tracer, name: str, parent: opt[SpanContext]) -> Span`

A new span: a child of parent (a caller's context, from parse_traceparent) or the root of a new trace.

### `fn child(s: Span, name: str) -> Span`

A span inside s, in the same trace.

### `fn set_kind(s: Span, kind: int)`

### `fn set_str(s: Span, key: str, v: str)`

### `fn set_int(s: Span, key: str, v: int)`

### `fn set_float(s: Span, key: str, v: float)`

### `fn set_bool(s: Span, key: str, v: bool)`

### `fn set_error(s: Span, msg: str)`

Marks the span failed, with a message.

### `fn set_ok(s: Span)`

### `fn end(s: Span)`

Ends the span and queues it for export. A second end does nothing.

### `fn traceparent(s: Span) -> str`

The traceparent header value for s: "00-<trace>-<span>-<flags>".

### `fn parse_traceparent(h: str) -> opt[SpanContext]`

The caller's span context from a traceparent header; none if the value is missing or malformed (start a new trace then).

### `fn flush(t: Tracer, deadline: until) -> result[int, str]`

Sends every queued span now. Returns how many were sent.

### `fn drain(t: Tracer) -> [Span]`

Ended spans not yet sent, removed from the queue: for a tracer with no endpoint, as in tests.

### `struct Counts`

### `fn counts(t: Tracer) -> Counts`

### `fn encode_otlp(t: Tracer, spans: [Span]) -> bytes`

The OTLP/HTTP JSON body for spans (ExportTraceServiceRequest).

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
