import "builder";

let B = "XyZzY123";

fn sample() -> bytes {
    return to_bytes("preamble to ignore\r\n--XyZzY123\r\n" +
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
        "Hello\r\n--world\r\n" +                                  // a near miss inside data
        "--XyZzY123\r\n" +
        "Content-Disposition: form-data; name=\"doc\"; filename=\"a b.txt\"; filename*=UTF-8''na%C3%AFve.txt\r\n" +
        "Content-Type: text/markdown\r\n\r\n" +
        "line1\r\n--XyZzY12\r\nline3" +                          // the boundary minus a byte
        "\r\n--XyZzY123\r\n" +
        "Content-Disposition: form-data; name=\"empty\"\r\n\r\n" +
        "\r\n--XyZzY123--\r\nepilogue");
}

fn test_should_read_the_boundary_from_the_content_type() {
    assert((boundary_of("multipart/form-data; boundary=abc") ?? "") == "abc", "plain");
    assert((boundary_of("Multipart/Form-Data; boundary=\"a b\"; charset=x") ?? "") == "a b", "quoted");
    if let _b = boundary_of("text/plain; boundary=x") { panic("not multipart"); }
    if let _c = boundary_of("multipart/form-data") { panic("no boundary"); }
}

fn test_should_parse_fields_files_and_near_misses() {
    let r = parse(sample(), B);
    guard let items = r else let e = err_of(r) { panic(e); }
    assert(len(items) == 3, "parts " + to_str(len(items)));
    assert(items[0].part.name == "title" && items[0].data == b"Hello\r\n--world", "field: " + to_str(items[0].data));
    assert(items[1].part.filename == "naïve.txt" && items[1].part.content_type == "text/markdown", "file");
    assert(items[1].data == b"line1\r\n--XyZzY12\r\nline3", "near-miss boundary in data");
    assert(items[2].part.name == "empty" && len(items[2].data) == 0, "empty part");
}

fn test_should_give_the_same_parts_one_byte_at_a_time() {
    let body = sample();
    let p = parser(B);
    let names: [str] = [];
    let datas: [bytes] = [];
    let cur = builder.new_bytes();
    for i in 0..len(body) {
        let er = feed(p, body[i..i + 1]);
        guard let evs = er else let e = err_of(er) { panic(e); }
        for e in evs {
            if e.kind == PART { push(names, e.part.name); cur = builder.new_bytes(); }
            else if e.kind == DATA { cur.write(e.data); }
            else if e.kind == PART_END { push(datas, cur.finish()); }
        }
    }
    assert(is_ok(finish(p)), "finish");
    assert(len(names) == 3 && names[1] == "doc", "names");
    assert(datas[1] == b"line1\r\n--XyZzY12\r\nline3", "streamed data");
}

fn is_ok(r: result[bool, str]) -> bool {
    if let _v = r { return true; }
    return false;
}

fn test_should_refuse_truncated_and_oversized_bodies() {
    let cut = sample()[0..60];
    let p = parser(B);
    let _e = feed(p, cut);
    assert(!is_ok(finish(p)), "truncated body finished");
    let big = to_bytes("--XyZzY123\r\nX-Junk: ") + to_bytes(strings_repeat("a", 9000));
    let q = parser(B);
    if let _x = feed(q, big) { panic("oversized headers accepted"); }
    let many = builder.new_bytes();
    for _ in 0..5 { many.write_str("--XyZzY123\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n"); }
    let m = parser(B);
    m.max_parts = 3;
    if let _y = feed(m, many.finish()) { panic("too many parts accepted"); }
}

fn strings_repeat(s: str, n: int) -> str {
    let out = builder.new_bytes();
    for _ in 0..n { out.write_str(s); }
    return to_str(out.finish());
}

fn test_should_build_a_body_that_parses_back() {
    let w = body("bnd0123456789abcdef");
    add_field(w, "name", "Ada \"the\" Countess");
    add_file(w, "avatar", "me.png", "image/png", b"\x89PNG\r\n\x1a\n");
    let data = close(w);
    assert(content_type(w) == "multipart/form-data; boundary=bnd0123456789abcdef", "content type");
    let r = parse(data, "bnd0123456789abcdef");
    guard let items = r else let e = err_of(r) { panic(e); }
    assert(len(items) == 2 && items[0].part.name == "name" && to_str(items[0].data) == "Ada \"the\" Countess", "field back");
    assert(items[1].part.filename == "me.png" && items[1].data == b"\x89PNG\r\n\x1a\n", "file back");
}
