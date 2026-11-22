// Prometheus metrics: counters, gauges and histograms with labels, and
// the text exposition format a Prometheus server scrapes.
//
//     import "metrics";
//
//     let reg = metrics.registry();
//     let reqs = metrics.counter(reg, "http_requests_total",
//                                "Requests served.", ["method", "code"]);
//     let lat = metrics.histogram(reg, "http_request_duration_seconds",
//                                 "Request latency.", ["route"],
//                                 metrics.default_buckets());
//
//     metrics.inc(metrics.with(reqs, ["GET", "200"]));
//     let users = metrics.with(lat, ["/users"]);   // keep the series: no
//     metrics.observe(users, 0.012);               // label lookup per call
//
//     // GET /metrics answers metrics.expose(reg) with
//     // metrics.CONTENT_TYPE.
//
// Each series has its own lock, so tasks updating different series do not
// wait for each other; with() looks the labels up once, and a series kept
// by the caller costs one lock per update. Histograms are classic
// fixed-bucket ones (what Prometheus scrapes): a few ints a series, and a
// binary search per observation.

import "strings";

pub let CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8";

let COUNTER = 0;
let GAUGE = 1;
let HISTOGRAM = 2;

pub gc struct Series {
    kind: int,
    labels: [str],
    mu: mutex,
    v: float,          // counter or gauge value
    bounds: [float],   // histogram upper bounds, ascending (shared)
    counts: [int],     // per bucket, not cumulative; last is +Inf
    sum: float,
    count: int,
}

pub gc struct Family {
    kind: int,
    name: str,
    help: str,
    label_names: [str],
    bounds: [float],
    mu: mutex,
    series: map[str]Series,
}

pub gc struct Registry {
    mu: mutex,
    families: map[str]Family,
}

pub fn registry() -> Registry {
    let m: map[str]Family = {};
    return Registry { mu: make_mutex(), families: m };
}

// Prometheus's default latency buckets, in seconds.
pub fn default_buckets() -> [float] {
    return [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0];
}

// count bounds from start, each factor times the last.
pub fn exponential_buckets(start: float, factor: float, count: int) -> [float] {
    let out: [float] = [];
    let v = start;
    for _ in 0..count {
        push(out, v);
        v = v * factor;
    }
    return out;
}

// A counter family: a value that only goes up (inc, add).
pub fn counter(r: Registry, name: str, help: str, labels: [str]) -> Family {
    return register(r, COUNTER, name, help, labels, []);
}

// A gauge family: a value that goes up and down (set, add, inc, dec).
pub fn gauge(r: Registry, name: str, help: str, labels: [str]) -> Family {
    return register(r, GAUGE, name, help, labels, []);
}

// A histogram family with these upper bounds (ascending; +Inf is added).
pub fn histogram(r: Registry, name: str, help: str, labels: [str],
                 bounds: [float]) -> Family {
    for i in 1..len(bounds) {
        if !(bounds[i] > bounds[i - 1]) {
            panic("metrics: histogram " + name + ": bounds must ascend");
        }
    }
    return register(r, HISTOGRAM, name, help, labels, bounds);
}

// The series for these label values (one per label name, in order),
// made on first use. Keep it to skip this lookup on every update.
pub fn with(f: Family, values: [str]) -> Series {
    if len(values) != len(f.label_names) {
        panic("metrics: " + f.name + " takes " + to_str(len(f.label_names)) +
              " label values, got " + to_str(len(values)));
    }
    let key = strings.join(values, "\x00");
    mutex_lock(f.mu);
    if has(f.series, key) {
        let s = f.series[key];
        mutex_unlock(f.mu);
        return s;
    }
    let counts: [int] = [];
    if f.kind == HISTOGRAM {
        for _ in 0..len(f.bounds) + 1 { push(counts, 0); }
    }
    let copy: [str] = [];
    for v in values { push(copy, v); }
    let s = Series { kind: f.kind, labels: copy, mu: make_mutex(), v: 0.0,
                     bounds: f.bounds, counts: counts, sum: 0.0, count: 0 };
    f.series[key] = s;
    mutex_unlock(f.mu);
    return s;
}

// Drops a series (a label value that will not come back, such as a
// finished job's id), so a family's memory does not grow without bound.
pub fn remove(f: Family, values: [str]) {
    let key = strings.join(values, "\x00");
    mutex_lock(f.mu);
    if has(f.series, key) {
        del(f.series, key);
    }
    mutex_unlock(f.mu);
}

pub fn inc(s: Series) {
    add(s, 1.0);
}

// Adds v. A counter panics on a negative v: counters only go up, and a
// decrease reads as a reset to every rate() over it.
pub fn add(s: Series, v: float) {
    if s.kind == HISTOGRAM {
        panic("metrics: add on a histogram; use observe");
    }
    if s.kind == COUNTER && v < 0.0 {
        panic("metrics: a counter cannot go down");
    }
    mutex_lock(s.mu);
    s.v = s.v + v;
    mutex_unlock(s.mu);
}

pub fn dec(s: Series) {
    if s.kind != GAUGE {
        panic("metrics: dec on a counter or histogram");
    }
    mutex_lock(s.mu);
    s.v = s.v - 1.0;
    mutex_unlock(s.mu);
}

pub fn set(s: Series, v: float) {
    if s.kind != GAUGE {
        panic("metrics: set on a counter or histogram");
    }
    mutex_lock(s.mu);
    s.v = v;
    mutex_unlock(s.mu);
}

// Records one value into a histogram.
pub fn observe(s: Series, v: float) {
    if s.kind != HISTOGRAM {
        panic("metrics: observe on a counter or gauge");
    }
    // the first bound >= v (le is inclusive); NaN lands in +Inf
    let lo = 0;
    let hi = len(s.bounds);
    while lo < hi {
        let mid = (lo + hi) / 2;
        if v <= s.bounds[mid] { hi = mid; } else { lo = mid + 1; }
    }
    mutex_lock(s.mu);
    s.counts[lo] = s.counts[lo] + 1;
    s.sum = s.sum + v;
    s.count = s.count + 1;
    mutex_unlock(s.mu);
}

// A counter's or gauge's value now.
pub fn value(s: Series) -> float {
    mutex_lock(s.mu);
    let v = s.v;
    mutex_unlock(s.mu);
    return v;
}

// Every family in the text exposition format, families by name and
// series by labels, so two scrapes of an idle program are identical.
pub fn expose(r: Registry) -> str {
    mutex_lock(r.mu);
    let names: [str] = [];
    for k, _v in r.families { push(names, k); }
    let fams: [Family] = [];
    sort_strs(names);
    for n in names { push(fams, r.families[n]); }
    mutex_unlock(r.mu);
    let out: [str] = [];
    for f in fams {
        write_family(out, f);
    }
    return strings.join(out, "");
}

// ---- internals -----------------------------------------------------------

fn register(r: Registry, kind: int, name: str, help: str, labels: [str],
            bounds: [float]) -> Family {
    if !valid_name(name, true) {
        panic("metrics: invalid metric name '" + name + "'");
    }
    for l in labels {
        if !valid_name(l, false) || strings.has_prefix(l, "__") ||
           (kind == HISTOGRAM && l == "le") {
            panic("metrics: invalid label name '" + l + "' on " + name);
        }
    }
    mutex_lock(r.mu);
    if has(r.families, name) {
        mutex_unlock(r.mu);
        panic("metrics: " + name + " registered twice");
    }
    let m: map[str]Series = {};
    let names: [str] = [];
    for l in labels { push(names, l); }
    let f = Family { kind: kind, name: name, help: help, label_names: names,
                     bounds: bounds, mu: make_mutex(), series: m };
    r.families[name] = f;
    mutex_unlock(r.mu);
    return f;
}

fn is_letter(c: int) -> bool {
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95;
}

fn is_digit(c: int) -> bool {
    return c >= 48 && c <= 57;
}

// [a-zA-Z_:][a-zA-Z0-9_:]* for metric names (colons allowed), the same
// without colons for label names.
fn valid_name(s: str, colons: bool) -> bool {
    let b = to_bytes(s);
    if len(b) == 0 { return false; }
    for i in 0..len(b) {
        let c = b[i] as int;
        let ok = is_letter(c) || (colons && c == 58) || (i > 0 && is_digit(c));
        if !ok { return false; }
    }
    return true;
}

fn sort_strs(xs: [str]) {
    // insertion sort: families and series are few, and this keeps the
    // package free of a dependency for it
    for i in 1..len(xs) {
        let x = xs[i];
        let j = i - 1;
        while j >= 0 && xs[j] > x {
            xs[j + 1] = xs[j];
            j = j - 1;
        }
        xs[j + 1] = x;
    }
}

fn kind_name(k: int) -> str {
    if k == COUNTER { return "counter"; }
    if k == GAUGE { return "gauge"; }
    return "histogram";
}

fn fmt_float(v: float) -> str {
    if v != v { return "NaN"; }
    if v > 1.7976931348623157e308 { return "+Inf"; }
    if v < -1.7976931348623157e308 { return "-Inf"; }
    return to_str(v);
}

// HELP text: backslash and newline escaped.
fn esc_help(s: str) -> str {
    return strings.replace(strings.replace(s, "\\", "\\\\"), "\n", "\\n");
}

// A label value: backslash, double quote and newline escaped.
fn esc_label(s: str) -> str {
    return strings.replace(strings.replace(strings.replace(s, "\\", "\\\\"),
                                           "\"", "\\\""), "\n", "\\n");
}

fn label_text(names: [str], values: [str], extra_name: str, extra: str) -> str {
    let parts: [str] = [];
    for i in 0..len(names) {
        push(parts, names[i] + "=\"" + esc_label(values[i]) + "\"");
    }
    if len(extra_name) > 0 {
        push(parts, extra_name + "=\"" + extra + "\"");
    }
    if len(parts) == 0 { return ""; }
    return "{" + strings.join(parts, ",") + "}";
}

fn write_family(out: [str], f: Family) {
    mutex_lock(f.mu);
    let keys: [str] = [];
    for k, _s in f.series { push(keys, k); }
    sort_strs(keys);
    let series: [Series] = [];
    for k in keys { push(series, f.series[k]); }
    mutex_unlock(f.mu);
    if len(f.help) > 0 {
        push(out, "# HELP " + f.name + " " + esc_help(f.help) + "\n");
    }
    push(out, "# TYPE " + f.name + " " + kind_name(f.kind) + "\n");
    for s in series {
        mutex_lock(s.mu);
        let v = s.v;
        let counts: [int] = [];
        for c in s.counts { push(counts, c); }
        let sum = s.sum;
        let count = s.count;
        mutex_unlock(s.mu);
        if f.kind != HISTOGRAM {
            push(out, f.name + label_text(f.label_names, s.labels, "", "") + " " +
                      fmt_float(v) + "\n");
            continue;
        }
        let cum = 0;
        for i in 0..len(f.bounds) {
            cum = cum + counts[i];
            push(out, f.name + "_bucket" +
                      label_text(f.label_names, s.labels, "le", fmt_float(f.bounds[i])) +
                      " " + to_str(cum) + "\n");
        }
        cum = cum + counts[len(f.bounds)];
        push(out, f.name + "_bucket" + label_text(f.label_names, s.labels, "le", "+Inf") +
                  " " + to_str(cum) + "\n");
        push(out, f.name + "_sum" + label_text(f.label_names, s.labels, "", "") + " " +
                  fmt_float(sum) + "\n");
        push(out, f.name + "_count" + label_text(f.label_names, s.labels, "", "") + " " +
                  to_str(count) + "\n");
    }
}
