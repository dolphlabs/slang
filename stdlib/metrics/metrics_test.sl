import "strings";

fn test_should_expose_the_text_format_exactly() {
    let reg = registry();
    let c = counter(reg, "http_requests_total", "Requests served.", ["method", "code"]);
    inc(with(c, ["POST", "500"]));
    add(with(c, ["GET", "200"]), 2.0);
    let g = gauge(reg, "inflight", "", []);
    set(with(g, []), 3.0);
    dec(with(g, []));
    let h = histogram(reg, "lat_seconds", "Latency.", ["route"], [0.1, 1.0]);
    let a = with(h, ["/a"]);
    observe(a, 0.05);
    observe(a, 0.1);        // le is inclusive
    observe(a, 5.0);
    let want = "# HELP http_requests_total Requests served.\n" +
        "# TYPE http_requests_total counter\n" +
        "http_requests_total{method=\"GET\",code=\"200\"} 2\n" +
        "http_requests_total{method=\"POST\",code=\"500\"} 1\n" +
        "# TYPE inflight gauge\n" +
        "inflight 2\n" +
        "# HELP lat_seconds Latency.\n" +
        "# TYPE lat_seconds histogram\n" +
        "lat_seconds_bucket{route=\"/a\",le=\"0.1\"} 2\n" +
        "lat_seconds_bucket{route=\"/a\",le=\"1\"} 2\n" +
        "lat_seconds_bucket{route=\"/a\",le=\"+Inf\"} 3\n" +
        "lat_seconds_sum{route=\"/a\"} 5.15\n" +
        "lat_seconds_count{route=\"/a\"} 3\n";
    let got = expose(reg);
    assert(got == want, "exposition:\n" + got);
}

fn test_should_escape_help_and_label_values() {
    let reg = registry();
    let c = counter(reg, "x_total", "a \\ b\nc", ["path"]);
    inc(with(c, ["a\"b\\c\nd"]));
    let got = expose(reg);
    assert(strings.contains(got, "# HELP x_total a \\\\ b\\nc\n"), "help: " + got);
    assert(strings.contains(got, "x_total{path=\"a\\\"b\\\\c\\nd\"} 1\n"), "label: " + got);
}

fn test_should_print_special_floats() {
    let reg = registry();
    let g = gauge(reg, "g", "", ["k"]);
    set(with(g, ["nan"]), 0.0 / 0.0);
    set(with(g, ["pinf"]), 1.0 / 0.0);
    set(with(g, ["ninf"]), -1.0 / 0.0);
    let got = expose(reg);
    assert(strings.contains(got, "g{k=\"nan\"} NaN\n") && strings.contains(got, "g{k=\"pinf\"} +Inf\n") &&
           strings.contains(got, "g{k=\"ninf\"} -Inf\n"), got);
}

fn test_should_return_the_same_series_for_the_same_labels() {
    let reg = registry();
    let c = counter(reg, "c_total", "", ["a"]);
    inc(with(c, ["x"]));
    inc(with(c, ["x"]));
    assert(value(with(c, ["x"])) == 2.0, "series not shared");
    remove(c, ["x"]);
    assert(value(with(c, ["x"])) == 0.0, "removed series came back");
}

fn bump(s: Series, n: int, done: chan[int]) {
    for _ in 0..n { inc(s); }
    chan_send(done, 1);
}

fn test_should_count_every_increment_from_many_tasks() {
    let reg = registry();
    let s = with(counter(reg, "busy_total", "", []), []);
    let done: chan[int] = make_chan(16);
    for _ in 0..16 { spawn bump(s, 1000, done); }
    for _ in 0..16 { let _d = chan_recv(done); }
    assert(value(s) == 16000.0, "lost increments: " + to_str(value(s)));
}

fn bad_name() -> int { let _f = counter(registry(), "9bad", "", []); return 0; }
fn bad_label() -> int { let _f = counter(registry(), "ok_total", "", ["__x"]); return 0; }
fn le_label() -> int { let _f = histogram(registry(), "h", "", ["le"], [1.0]); return 0; }
fn twice() -> int { let r = registry(); let _a = gauge(r, "g", "", []); let _b = gauge(r, "g", "", []); return 0; }
fn down() -> int { add(with(counter(registry(), "c_total", "", []), []), -1.0); return 0; }
fn wrong_arity() -> int { let _s = with(counter(registry(), "c_total", "", ["a"]), []); return 0; }
fn unsorted() -> int { let _h = histogram(registry(), "h", "", [], [1.0, 0.5]); return 0; }
fn wrong_kind() -> int { observe(with(counter(registry(), "c_total", "", []), []), 1.0); return 0; }

fn panics(f: fn() -> int) -> bool {
    let h = spawn f();
    if let _v = join_wait(h) { return false; }
    return true;
}

fn test_should_refuse_misuse() {
    assert(panics(bad_name), "bad metric name");
    assert(panics(bad_label), "reserved label name");
    assert(panics(le_label), "le on a histogram");
    assert(panics(twice), "double registration");
    assert(panics(down), "counter decrease");
    assert(panics(wrong_arity), "label count");
    assert(panics(unsorted), "unsorted buckets");
    assert(panics(wrong_kind), "observe on a counter");
}

fn test_should_make_exponential_buckets() {
    let b = exponential_buckets(0.001, 10.0, 4);
    assert(len(b) == 4 && b[0] == 0.001 && b[3] > 0.99 && b[3] < 1.01, "buckets");
}
