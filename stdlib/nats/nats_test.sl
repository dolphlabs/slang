// Unit tests: `slangc test stdlib/nats`. The client against a real server
// is tests/live/nats; reconnection against a scripted server is
// tests/nats_reconnect.

fn head_of(line: str) -> MsgHead {
    let r = parse_msg_head(line);
    guard let h = r else let e = err_of(r) { panic(e); }
    return h;
}

fn head_err(line: str) -> str {
    let r = parse_msg_head(line);
    if let _h = r {
        panic("expected an error for " + line);
    }
    return err_of(r);
}

fn test_should_parse_msg_heads() {
    let h = head_of("MSG orders.new 7 12");
    assert(h.subject == "orders.new" && h.sid == 7 && h.reply == "" && h.total == 12 && h.hlen == 0, "MSG");
    let r = head_of("MSG a.b 3 _INBOX.x.1 0");
    assert(r.reply == "_INBOX.x.1" && r.total == 0, "MSG with reply");
    let hm = head_of("HMSG s 9 22 30");
    assert(hm.hlen == 22 && hm.total == 30 && hm.reply == "", "HMSG");
    let hr = head_of("HMSG s 9 rep 22 30");
    assert(hr.reply == "rep" && hr.hlen == 22, "HMSG with reply");
    let sp = head_of("MSG  a  1   5");
    assert(sp.total == 5, "repeated spaces");
}

fn test_should_reject_malformed_msg_heads() {
    assert(strings.contains(head_err("MSG a 1"), "malformed"), "too few fields");
    assert(strings.contains(head_err("MSG a 1 b c 5"), "malformed"), "too many fields");
    assert(strings.contains(head_err("MSG a 1 b c d e f 5"), "malformed"), "far too many fields");
    assert(strings.contains(head_err("MSG a x 5"), "sid"), "bad sid");
    assert(strings.contains(head_err("MSG a 1 -5"), "sizes"), "negative size");
    assert(strings.contains(head_err("MSG a 1 99999999999"), "sizes"), "eleven-digit size");
    assert(strings.contains(head_err("HMSG a 1 40 30"), "sizes"), "header past total");
}

fn test_should_parse_header_blocks() {
    let m = Msg { subject: "", reply: "", data: b"", headers: {}, status: 0 };
    let r = parse_headers("NATS/1.0\r\nA: 1\r\nB: x\r\nA: 2\r\n\r\n", m);
    guard let _ok = r else let e = err_of(r) { panic(e); }
    assert(len(m.headers["A"]) == 2 && (m.headers["A"])[1] == "2" && (m.headers["B"])[0] == "x", "values");
    let s = Msg { subject: "", reply: "", data: b"", headers: {}, status: 0 };
    parse_headers("NATS/1.0 503\r\n\r\n", s);
    assert(s.status == 503, "status");
    let d = Msg { subject: "", reply: "", data: b"", headers: {}, status: 0 };
    parse_headers("NATS/1.0 408 Request Timeout\r\n\r\n", d);
    assert(d.status == 408, "status with description");
    let bad = Msg { subject: "", reply: "", data: b"", headers: {}, status: 0 };
    assert(!is_ok_bool(parse_headers("HTTP/1.1 200\r\n\r\n", bad)), "wrong version line");
    assert(!is_ok_bool(parse_headers("NATS/1.0\r\nno colon\r\n\r\n", bad)), "line without colon");
}

fn test_should_build_header_blocks_and_refuse_injection() {
    let h: map[str][str] = {};
    h["K"] = ["v1", "v2"];
    let r = header_block(h);
    guard let b = r else let e = err_of(r) { panic(e); }
    assert(b == "NATS/1.0\r\nK: v1\r\nK: v2\r\n\r\n", b);
    let bad: map[str][str] = {};
    bad["K"] = ["v\r\nX: injected"];
    assert(!is_ok_str(header_block(bad)), "CRLF in a value");
    let badk: map[str][str] = {};
    badk["K:"] = ["v"];
    assert(!is_ok_str(header_block(badk)), "colon in a name");
}

fn test_should_validate_subjects() {
    assert(is_ok_bool(check_subject("a.b.c", false)), "plain");
    assert(is_ok_bool(check_subject("a.*.>", true)), "wildcards to subscribe");
    assert(!is_ok_bool(check_subject("a.*", false)), "wildcard to publish");
    assert(!is_ok_bool(check_subject("a b", true)), "space");
    assert(!is_ok_bool(check_subject("a\r\nPUB x 1", false)), "CRLF injection");
    assert(!is_ok_bool(check_subject("", true)), "empty");
    assert(!is_ok_bool(check_subject("a..b", true)), "empty token");
    assert(!is_ok_bool(check_subject(".a", true)), "leading dot");
}

fn test_should_parse_server_urls() {
    let a = parse_server("nats://127.0.0.1:4222") ?? Server { host: "", port: 0, tls: false, user: "", pass: "", token: "" };
    assert(a.host == "127.0.0.1" && a.port == 4222 && !a.tls, "plain");
    let b = parse_server("tls://alice:s3cret@nats.example:7422") ?? a;
    assert(b.tls && b.user == "alice" && b.pass == "s3cret" && b.host == "nats.example" && b.port == 7422, "tls with user");
    let c = parse_server("nats://tok123@host") ?? a;
    assert(c.token == "tok123" && c.port == 4222, "token, default port");
    let d = parse_server("nats://[::1]:4222") ?? a;
    assert(d.host == "::1", "IPv6");
    assert(!is_ok_server(parse_server("http://x")), "scheme");
    assert(!is_ok_server(parse_server("nats://x:99999")), "port");
    assert(!is_ok_server(parse_server("nats://")), "no host");
}

fn test_should_encode_base32_and_crc16_like_nkeys() {
    // CRC-16/XMODEM check value
    assert(crc16(b"123456789") == 12739, "crc16 of 123456789 is 0x31C3");
    assert(b32_encode(b"foobar") == "MZXW6YTBOI", b32_encode(b"foobar"));
    assert(b32_encode(b"f") == "MY", "one byte");
    let back = b32_decode("MZXW6YTBOI") ?? b"";
    assert(back == b"foobar", "decode");
    for n in 0..40 {
        let b = strings.bytes_zero(n);
        for i in 0..n { b[i] = (i * 37 + n) & 255; }
        assert((b32_decode(b32_encode(b)) ?? b"x") == b, "round trip " + to_str(n));
    }
}

fn test_should_reject_corrupt_or_wrong_seeds() {
    let seed = nkey_encode_seed(b"0123456789abcdef0123456789abcdef") ?? "";
    assert((nkey_seed_raw(seed) ?? b"") == b"0123456789abcdef0123456789abcdef", "round trip");
    // flip one character: the CRC catches it
    let bs = to_bytes(seed);
    bs[10] = if_else(bs[10] == 65, 66, 65);
    assert(strings.contains(err_of(nkey_seed_raw(to_str(bs))), "checksum"), "corruption");
    let pk = nkey_public(seed) ?? "";
    assert(strings.has_prefix(pk, "U") && len(pk) == 56, pk);
    assert(strings.contains(err_of(nkey_seed_raw(pk)), "not a seed"), "a public key is not a seed");
    assert(strings.contains(err_of(nkey_seed_raw("SU!!")), "base32"), "alphabet");
}

fn test_should_read_creds_files() {
    let text = "-----BEGIN NATS USER JWT-----\neyJ0eXAiOiJKV1QifQ.e30.sig\n------END NATS USER JWT------\n\n" +
               "************************* IMPORTANT *************************\n\n" +
               "-----BEGIN USER NKEY SEED-----\nSUAEXAMPLE\n------END USER NKEY SEED------\n";
    let r = parse_creds(text);
    guard let parts = r else let e = err_of(r) { panic(e); }
    assert(parts[0] == "eyJ0eXAiOiJKV1QifQ.e30.sig" && parts[1] == "SUAEXAMPLE", parts[0]);
    assert(!is_ok_list(parse_creds("nothing here")), "missing blocks");
}

fn test_should_build_connect_json_without_secrets_leaking_into_other_fields() {
    let o = options("nats://127.0.0.1:4222");
    o.name = "svc \"one\"";
    let nc = Conn {
        opts: o, servers: [], current: 0, fd: -1, ssl: nullptr, tls_ctx: nullptr,
        state: 0, why: "", max_payload: 1048576, headers_ok: true,
        wlock: make_mutex(), iolock: make_mutex(), out: builder.new_bytes(),
        kicked: false, last_flush: 0, kick: make_chan(1),
        slock: make_mutex(), subs: {}, next_sid: 1, pongs: [], pings_out: 0,
        inbox: "_INBOX.t", resp_sub: 0, resp: {}, next_token: 1, waiters: [],
        tick: make_chan(1), rng: rand.new(1), reconnects: 0, reader_done: make_chan(1)
    };
    let s = Server { host: "h", port: 1, tls: false, user: "u\"x", pass: "p", token: "" };
    let j = connect_json(nc, s, "") ?? "";
    assert(strings.contains(j, "\"name\":\"svc \\\"one\\\"\""), j);
    assert(strings.contains(j, "\"user\":\"u\\\"x\""), j);
    assert(strings.contains(j, "\"headers\":true") && strings.contains(j, "\"no_responders\":true"), j);
    o.nkey_seed = nkey_encode_seed(b"0123456789abcdef0123456789abcdef") ?? "";
    assert(strings.contains(err_of(connect_json(nc, s, "")), "no nonce"), "nkey without a nonce");
    let jn = connect_json(nc, s, "nonce-1") ?? "";
    assert(strings.contains(jn, "\"sig\":\"") && strings.contains(jn, "\"nkey\":\"U"), jn);
}

fn if_else(c: bool, a: int, b: int) -> int {
    if c { return a; }
    return b;
}
fn is_ok_bool(r: result[bool, str]) -> bool {
    if let _v = r { return true; }
    return false;
}
fn is_ok_str(r: result[str, str]) -> bool {
    if let _v = r { return true; }
    return false;
}
fn is_ok_list(r: result[[str], str]) -> bool {
    if let _v = r { return true; }
    return false;
}
fn is_ok_server(r: result[Server, str]) -> bool {
    if let _v = r { return true; }
    return false;
}
