// Distributed tracing: spans with W3C trace context propagation
// (`traceparent`), exported to an OpenTelemetry collector over OTLP/HTTP
// with JSON bodies.
//
//     import "trace";
//
//     let t = trace.tracer("checkout", "http://otel-collector:4318");
//     // a request came in: continue the caller's trace if it sent one
//     let parent = trace.parse_traceparent(req_header("traceparent") ?? "");
//     let span = trace.start(t, "POST /orders", parent);
//     trace.set_str(span, "http.route", "/orders");
//     let db = trace.child(span, "insert order");
//     ... // the query
//     trace.end(db);
//     // calling another service: send our place in the trace along
//     headers["traceparent"] = trace.traceparent(span);
//     trace.end(span);
//
// Ended spans are queued and sent in batches by a background task; the
// queue is bounded (spans past it are dropped and counted), so a dead
// collector costs at most max_queue spans of memory. Unsampled spans
// (sample_ratio, and the caller's sampled flag when continuing a trace)
// record nothing and are never queued.

import "httpc";
import "json";
import "rand";
import "strings";
import "time";

pub struct Options {
    // Share of new traces recorded, from 0 to 1. A trace continued from
    // a caller follows the caller's decision.
    sample_ratio: float,
    // Spans sent per request to the collector.
    max_batch: int,
    // Ended spans held for sending at most; more are dropped.
    max_queue: int,
    // Nanoseconds between background sends of a partial batch.
    flush_ns: int,
}

pub fn options() -> Options {
    return Options { sample_ratio: 1.0, max_batch: 512, max_queue: 4096,
                     flush_ns: 5000000000 };
}

// A span's place in a trace, as traceparent carries it.
pub struct SpanContext {
    trace_id: str,     // 32 lower-case hex digits
    span_id: str,      // 16
    sampled: bool,
}

pub struct Attr {
    key: str,
    kind: int,         // ATTR_STR, ATTR_INT, ATTR_FLOAT, ATTR_BOOL
    s: str,
    i: int,
    f: float,
    b: bool,
}

pub gc struct Span {
    t: Tracer,
    ctx: SpanContext,
    parent_span_id: str,
    name: str,
    kind: int,
    start_ns: int,
    end_ns: int,
    attrs: [Attr],
    status: int,       // 0 unset, 1 ok, 2 error
    status_msg: str,
    ended: bool,
}

pub gc struct Tracer {
    service: str,
    endpoint: str,     // collector base URL; "" keeps spans for drain()
    o: Options,
    mu: mutex,
    rng: rand.Rng,
    queue: [Span],
    dropped: int,
    exported: int,
    failures: int,
    last_error: str,
    flushing: bool,
    client: httpc.Client,
}

pub let KIND_INTERNAL = 1;
pub let KIND_SERVER = 2;
pub let KIND_CLIENT = 3;
pub let KIND_PRODUCER = 4;
pub let KIND_CONSUMER = 5;

let ATTR_STR = 0;
let ATTR_INT = 1;
let ATTR_FLOAT = 2;
let ATTR_BOOL = 3;

// A tracer for one service. endpoint is the collector's base URL (spans
// go to endpoint + "/v1/traces"); "" exports nothing and keeps ended
// spans for drain(), for tests.
pub fn tracer(service: str, endpoint: str) -> Tracer {
    return tracer_with(service, endpoint, options());
}

pub fn tracer_with(service: str, endpoint: str, o: Options) -> Tracer {
    let seed = rand.new(time.wall() as int);
    let r = rand.from_os() ?? seed;
    let q: [Span] = [];
    let mo = o;
    if mo.max_batch < 1 { mo.max_batch = 1; }
    if mo.max_queue < mo.max_batch { mo.max_queue = mo.max_batch; }
    let ep = endpoint;
    while strings.has_suffix(ep, "/") { ep = strings.slice(ep, 0, len(ep) - 1); }
    let t = Tracer { service: service, endpoint: ep,
                     o: mo, mu: make_mutex(), rng: r, queue: q, dropped: 0,
                     exported: 0, failures: 0, last_error: "", flushing: false,
                     client: httpc.new_client() };
    if len(t.endpoint) > 0 {
        spawn ticker(t);
    }
    return t;
}

// A new span: a child of parent (a caller's context, from
// parse_traceparent) or the root of a new trace.
pub fn start(t: Tracer, name: str, parent: opt[SpanContext]) -> Span {
    mutex_lock(t.mu);
    let span_id = hex64(rand.next_u64(t.rng));
    let trace_id = "";
    let parent_id = "";
    let sampled = false;
    if let p = parent {
        trace_id = p.trace_id;
        parent_id = p.span_id;
        sampled = p.sampled;
    } else {
        trace_id = hex64(rand.next_u64(t.rng)) + hex64(rand.next_u64(t.rng));
        sampled = rand.unit(t.rng) < t.o.sample_ratio;
    }
    mutex_unlock(t.mu);
    let attrs: [Attr] = [];
    let kind = KIND_INTERNAL;
    if len(parent_id) > 0 { kind = KIND_SERVER; }
    return Span { t: t, ctx: SpanContext { trace_id: trace_id, span_id: span_id,
                                           sampled: sampled },
                  parent_span_id: parent_id, name: name, kind: kind,
                  start_ns: time.wall() as int, end_ns: 0, attrs: attrs,
                  status: 0, status_msg: "", ended: false };
}

// A span inside s, in the same trace.
pub fn child(s: Span, name: str) -> Span {
    let c = start(s.t, name, some(s.ctx));
    c.kind = KIND_INTERNAL;
    return c;
}

pub fn set_kind(s: Span, kind: int) { s.kind = kind; }

pub fn set_str(s: Span, key: str, v: str) {
    if !s.ctx.sampled { return; }
    push(s.attrs, Attr { key: key, kind: ATTR_STR, s: v, i: 0, f: 0.0, b: false });
}

pub fn set_int(s: Span, key: str, v: int) {
    if !s.ctx.sampled { return; }
    push(s.attrs, Attr { key: key, kind: ATTR_INT, s: "", i: v, f: 0.0, b: false });
}

pub fn set_float(s: Span, key: str, v: float) {
    if !s.ctx.sampled { return; }
    push(s.attrs, Attr { key: key, kind: ATTR_FLOAT, s: "", i: 0, f: v, b: false });
}

pub fn set_bool(s: Span, key: str, v: bool) {
    if !s.ctx.sampled { return; }
    push(s.attrs, Attr { key: key, kind: ATTR_BOOL, s: "", i: 0, f: 0.0, b: v });
}

// Marks the span failed, with a message.
pub fn set_error(s: Span, msg: str) {
    s.status = 2;
    s.status_msg = msg;
}

pub fn set_ok(s: Span) {
    s.status = 1;
}

// Ends the span and queues it for export. A second end does nothing.
pub fn end(s: Span) {
    if s.ended { return; }
    s.ended = true;
    s.end_ns = time.wall() as int;
    if !s.ctx.sampled { return; }
    let t = s.t;
    mutex_lock(t.mu);
    if len(t.queue) >= t.o.max_queue {
        t.dropped = t.dropped + 1;
        mutex_unlock(t.mu);
        return;
    }
    push(t.queue, s);
    let full = len(t.queue) >= t.o.max_batch && len(t.endpoint) > 0 && !t.flushing;
    if full { t.flushing = true; }
    mutex_unlock(t.mu);
    if full {
        spawn flush_task(t);
    }
}

// The traceparent header value for s: "00-<trace>-<span>-<flags>".
pub fn traceparent(s: Span) -> str {
    let flags = "00";
    if s.ctx.sampled { flags = "01"; }
    return "00-" + s.ctx.trace_id + "-" + s.ctx.span_id + "-" + flags;
}

// The caller's span context from a traceparent header; none if the value
// is missing or malformed (start a new trace then).
pub fn parse_traceparent(h: str) -> opt[SpanContext] {
    let v = strings.trim(h);
    let parts = strings.split(v, "-");
    if len(parts) < 4 { return none; }
    let ver = parts[0];
    if len(ver) != 2 || !is_hex(ver) || ver == "ff" { return none; }
    // version 00 has exactly four fields; later versions may add more
    if ver == "00" && len(parts) != 4 { return none; }
    let tid = parts[1];
    let sid = parts[2];
    let fl = parts[3];
    if len(tid) != 32 || len(sid) != 16 || len(fl) != 2 { return none; }
    if !is_hex(tid) || !is_hex(sid) || !is_hex(fl) { return none; }
    if tid == "00000000000000000000000000000000" || sid == "0000000000000000" {
        return none;
    }
    let flags = hex_byte(fl);
    return some(SpanContext { trace_id: tid, span_id: sid, sampled: (flags & 1) == 1 });
}

// Sends every queued span now. Returns how many were sent.
pub fn flush(t: Tracer, deadline: until) -> result[int, str] {
    mutex_lock(t.mu);
    let batch = t.queue;
    let empty: [Span] = [];
    t.queue = empty;
    mutex_unlock(t.mu);
    if len(batch) == 0 || len(t.endpoint) == 0 {
        if len(t.endpoint) == 0 {
            // nowhere to send: keep them for drain()
            mutex_lock(t.mu);
            for s in batch { push(t.queue, s); }
            mutex_unlock(t.mu);
        }
        return ok(0);
    }
    let sent = 0;
    let at = 0;
    while at < len(batch) {
        let end_at = at + t.o.max_batch;
        if end_at > len(batch) { end_at = len(batch); }
        let body = encode_otlp(t, batch[at..end_at]);
        let r = httpc.client_post(t.client, t.endpoint + "/v1/traces",
                                  "application/json", body, deadline);
        guard let resp = r else let e = err_of(r) {
            note_failure(t, e, len(batch) - at);
            return err(e);
        }
        if resp.status < 200 || resp.status > 299 {
            let msg = "collector answered " + to_str(resp.status);
            note_failure(t, msg, len(batch) - at);
            return err(msg);
        }
        sent = sent + (end_at - at);
        at = end_at;
    }
    mutex_lock(t.mu);
    t.exported = t.exported + sent;
    mutex_unlock(t.mu);
    return ok(sent);
}

// Ended spans not yet sent, removed from the queue: for a tracer with no
// endpoint, as in tests.
pub fn drain(t: Tracer) -> [Span] {
    mutex_lock(t.mu);
    let q = t.queue;
    let empty: [Span] = [];
    t.queue = empty;
    mutex_unlock(t.mu);
    return q;
}

pub struct Counts {
    exported: int,
    dropped: int,       // past max_queue, or lost in a failed send
    failures: int,      // sends that failed
    queued: int,
    last_error: str,
}

pub fn counts(t: Tracer) -> Counts {
    mutex_lock(t.mu);
    let c = Counts { exported: t.exported, dropped: t.dropped, failures: t.failures,
                     queued: len(t.queue), last_error: t.last_error };
    mutex_unlock(t.mu);
    return c;
}

// The OTLP/HTTP JSON body for spans (ExportTraceServiceRequest).
pub fn encode_otlp(t: Tracer, spans: [Span]) -> bytes {
    let out: [str] = [];
    push(out, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":");
    push(out, json.encode(t.service));
    push(out, "}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"slang/trace\"},\"spans\":[");
    for i in 0..len(spans) {
        if i > 0 { push(out, ","); }
        write_span(out, spans[i]);
    }
    push(out, "]}]}]}");
    return to_bytes(strings.join(out, ""));
}

// ---- internals -----------------------------------------------------------

fn write_span(out: [str], s: Span) {
    push(out, "{\"traceId\":\"" + s.ctx.trace_id + "\",\"spanId\":\"" + s.ctx.span_id + "\"");
    if len(s.parent_span_id) > 0 {
        push(out, ",\"parentSpanId\":\"" + s.parent_span_id + "\"");
    }
    push(out, ",\"name\":" + json.encode(s.name) + ",\"kind\":" + to_str(s.kind));
    // 64-bit integers are strings in protobuf's JSON mapping
    push(out, ",\"startTimeUnixNano\":\"" + to_str(s.start_ns) + "\",\"endTimeUnixNano\":\"" +
              to_str(s.end_ns) + "\"");
    if len(s.attrs) > 0 {
        push(out, ",\"attributes\":[");
        for i in 0..len(s.attrs) {
            if i > 0 { push(out, ","); }
            let a = s.attrs[i];
            push(out, "{\"key\":" + json.encode(a.key) + ",\"value\":{");
            if a.kind == ATTR_STR {
                push(out, "\"stringValue\":" + json.encode(a.s));
            } else if a.kind == ATTR_INT {
                push(out, "\"intValue\":\"" + to_str(a.i) + "\"");
            } else if a.kind == ATTR_FLOAT {
                push(out, "\"doubleValue\":" + json.encode(a.f));
            } else {
                push(out, "\"boolValue\":" + to_str(a.b));
            }
            push(out, "}}");
        }
        push(out, "]");
    }
    if s.status != 0 {
        push(out, ",\"status\":{\"code\":" + to_str(s.status));
        if len(s.status_msg) > 0 {
            push(out, ",\"message\":" + json.encode(s.status_msg));
        }
        push(out, "}");
    }
    push(out, "}");
}

fn note_failure(t: Tracer, e: str, lost: int) {
    mutex_lock(t.mu);
    t.failures = t.failures + 1;
    t.dropped = t.dropped + lost;
    t.last_error = e;
    mutex_unlock(t.mu);
}

fn flush_task(t: Tracer) {
    let _r = flush(t, until_of(time.mono() + 10000000000));
    mutex_lock(t.mu);
    t.flushing = false;
    mutex_unlock(t.mu);
}

// Sends partial batches every flush_ns, for the life of the program.
fn ticker(t: Tracer) {
    while true {
        time.sleep(t.o.flush_ns);
        mutex_lock(t.mu);
        let go = len(t.queue) > 0 && !t.flushing;
        if go { t.flushing = true; }
        mutex_unlock(t.mu);
        if go {
            flush_task(t);
        }
    }
}

let HEX = "0123456789abcdef";

fn hex64(v: u64) -> str {
    let b: [str] = [];
    let shift = 60;
    while shift >= 0 {
        let d = ((v >> shift) & 15) as int;
        push(b, strings.slice(HEX, d, d + 1));
        shift = shift - 4;
    }
    return strings.join(b, "");
}

fn is_hex(s: str) -> bool {
    let bs = to_bytes(s);
    for i in 0..len(bs) {
        let c = bs[i] as int;
        if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) { return false; }
    }
    return true;
}

fn hex_byte(s: str) -> int {
    return strings.find(HEX, strings.slice(s, 0, 1)) * 16 + strings.find(HEX, strings.slice(s, 1, 2));
}
