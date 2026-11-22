fn kinds(evs: [Event]) -> str {
    let s = "";
    for e in evs { s = s + e.kind + "=" + e.data + ";"; }
    return s;
}

fn test_should_format_events() {
    assert(to_str(event("tick", "a\nb", "7")) == "event: tick\nid: 7\ndata: a\ndata: b\n\n", to_str(event("tick", "a\nb", "7")));
    assert(to_str(event("", "x", "")) == "data: x\n\n", "default kind");
    assert(to_str(event("bad\nkind", "x", "")) == "event: badkind\ndata: x\n\n", "newline in a field");
    assert(to_str(comment("ping")) == ": ping\n\n" && to_str(retry(3000)) == "retry: 3000\n\n", "comment and retry");
}

// The HTML spec's own examples.
fn test_should_parse_the_spec_examples() {
    let p = parser();
    let evs = feed(p, b"data: YHOO\ndata: +2\ndata: 10\n\n");
    assert(kinds(evs) == "message=YHOO\n+2\n10;", kinds(evs));
    let q = parser();
    let e2 = feed(q, b": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n");
    assert(len(e2) == 3, "count");
    assert(e2[0].data == "first event" && e2[0].id == "1", "first");
    assert(e2[1].data == "second event" && e2[1].id == "", "id reset");
    assert(e2[2].data == " third event", "one space stripped");
    let r = parser();
    let e3 = feed(r, b"data\n\ndata\ndata\n\ndata:\n");
    assert(len(e3) == 2 && e3[0].data == "" && e3[1].data == "\n", "empty data: " + kinds(e3));
}

fn test_should_handle_line_endings_split_across_chunks() {
    let p = parser();
    let all: [Event] = [];
    for chunk in [b"event: up\r", b"\ndata: 1\r", b"\r", b"data: 2\rdata: 3\n", b"\n"] {
        for e in feed(p, chunk) { push(all, e); }
    }
    assert(kinds(all) == "up=1;message=2\n3;", kinds(all));
}

fn test_should_keep_the_last_id_and_read_retry() {
    let p = parser();
    let evs = feed(p, b"id: 41\ndata: a\n\ndata: b\n\nretry: 2500\nretry: soon\n\n");
    assert(evs[1].id == "41", "id carried to the next event");
    assert(retry_ms(p) == 2500, "retry");
}

fn test_should_skip_a_leading_byte_order_mark() {
    let p = parser();
    let evs = feed(p, b"\xef\xbb\xbfdata: x\n\n");
    assert(kinds(evs) == "message=x;", kinds(evs));
}
