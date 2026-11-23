import "builder";
import "net";
import "strings";
import "time";

fn soon() -> until { return until_of(time.mono() + 5000000000); }

fn ms(n: int) -> int { return n * 1000000; }

fn rec(name: str, rtype: int, ttl: int, value: str) -> Record {
    return Record { name: name, rtype: rtype, ttl: ttl, value: value, priority: 0, weight: 0, port: 0 };
}

// ---- a fake name server: UDP and TCP on one port --------------------------

gc struct Fake {
    mu: mutex,
    udp: i32,
    tcp: i32,
    port: int,
    zone: map[str][Record],
    nx: map[str]bool,
    soa: opt[Record],
    // How it misbehaves: answers truncated over UDP (full over TCP),
    // SERVFAIL, silence, a reply with the wrong id or garbage first, or
    // CNAMEs given without the records they point at.
    truncate: bool,
    servfail: bool,
    silent: bool,
    spoof_first: bool,
    garbage_first: bool,
    no_chase: bool,
    queries: int,
    tcp_queries: int,
    stop: bool,
}

fn zkey(rtype: int, name: str) -> str { return to_str(rtype) + " " + name; }

fn add(f: Fake, r: Record) {
    let k = zkey(r.rtype, r.name);
    if !has(f.zone, k) {
        let fresh: [Record] = [];
        f.zone[k] = fresh;
    }
    push(f.zone[k], r);
}

fn reply_for(f: Fake, q: Message, over_tcp: bool) -> Message {
    let none_yet: [Record] = [];
    let m = Message { id: q.id, response: true, authoritative: true, truncated: false,
                      recursion_desired: q.recursion_desired, recursion_available: true,
                      rcode: NOERROR, questions: q.questions, answers: none_yet,
                      authority: [], additional: [] };
    if f.servfail {
        m.rcode = SERVFAIL;
        return m;
    }
    let qn = q.questions[0];
    let name = qn.name;
    let hops = 0;
    while hops < 20 {
        let k = zkey(qn.qtype, name);
        if has(f.zone, k) {
            for r in f.zone[k] { push(m.answers, r); }
            break;
        }
        let ck = zkey(CNAME, name);
        if qn.qtype != CNAME && has(f.zone, ck) {
            let c = f.zone[ck][0];
            push(m.answers, c);
            if f.no_chase { break; }
            name = c.value;
            hops = hops + 1;
            continue;
        }
        if has(f.nx, name) { m.rcode = NXDOMAIN; }
        break;
    }
    if len(m.answers) == 0 {
        if let s = f.soa { push(m.authority, s); }
    }
    if f.truncate && !over_tcp {
        m.truncated = true;
        let cut: [Record] = [];
        m.answers = cut;
    }
    return m;
}

fn udp_loop(f: Fake) {
    while !f.stop {
        let rr = net.recv_from_until(f.udp as int, 65535, until_of(time.mono() + ms(50)));
        guard let got = rr else { continue; }
        let qr = decode(got[0]);
        guard let q = qr else { continue; }
        mutex_lock(f.mu);
        f.queries = f.queries + 1;
        let m = reply_for(f, q, false);
        let silent = f.silent;
        let spoof = f.spoof_first;
        let garbage = f.garbage_first;
        mutex_unlock(f.mu);
        if silent { continue; }
        if garbage { let _g = net.send_to(f.udp as int, b"\x01\x02\x03", got[1]); }
        if spoof {
            let wrong = Message { id: (q.id + 1) & 65535, response: true, authoritative: true,
                                  truncated: false, recursion_desired: true, recursion_available: true,
                                  rcode: NOERROR, questions: q.questions,
                                  answers: [rec(q.questions[0].name, A, 60, "203.0.113.66")],
                                  authority: [], additional: [] };
            let _w = net.send_to(f.udp as int, encode(wrong) ?? b"", got[1]);
        }
        let _s = net.send_to(f.udp as int, encode(m) ?? b"", got[1]);
    }
}

fn tcp_conn(f: Fake, fd: i32) {
    let buf = b"";
    while len(buf) < 2 || len(buf) < 2 + get16(buf, 0) {
        let rr = net.recv_until(fd as int, 65536, soon());
        guard let more = rr else { net.close(fd as int); return; }
        if len(more) == 0 { net.close(fd as int); return; }
        buf = buf + more;
    }
    let qr = decode(buf[2..2 + get16(buf, 0)]);
    guard let q = qr else { net.close(fd as int); return; }
    mutex_lock(f.mu);
    f.tcp_queries = f.tcp_queries + 1;
    let m = reply_for(f, q, true);
    mutex_unlock(f.mu);
    let body = encode(m) ?? b"";
    let out = builder.new_bytes();
    put16(out, len(body));
    out.write(body);
    let _s = net.send(fd, out.finish());
    net.close(fd as int);
}

fn tcp_loop(f: Fake) {
    while !f.stop {
        let ar = net.accept(f.tcp as int);
        guard let fd = ar else { return; }
        spawn tcp_conn(f, fd);
    }
}

fn fake() -> Fake {
    // UDP and TCP ports are separate: the free UDP port the kernel picks
    // can be taken for TCP by another process, which failed the run with
    // "Address already in use". Try another port when it is.
    let tries = 0;
    while true {
        let ur = net.udp_bind("127.0.0.1", 0);
        guard let u = ur else let e = err_of(ur) { panic("udp_bind: " + e); }
        let port = net.port(u as int) ?? 0;
        let tr = net.listen_with("127.0.0.1", port as int, "");
        if let t = tr {
            return fake_on(u, t, port as int);
        }
        net.close(u as int);
        tries += 1;
        if tries == 20 {
            panic("listen: " + err_of(tr));
        }
    }
    panic("unreachable");
}

fn fake_on(u: i32, t: i32, port: int) -> Fake {
    let z: map[str][Record] = {};
    let nx: map[str]bool = {};
    let f = Fake { mu: make_mutex(), udp: u, tcp: t, port: port, zone: z, nx: nx, soa: none,
                   truncate: false, servfail: false, silent: false, spoof_first: false,
                   garbage_first: false, no_chase: false, queries: 0, tcp_queries: 0, stop: false };
    spawn udp_loop(f);
    spawn tcp_loop(f);
    return f;
}

fn stop(f: Fake) {
    f.stop = true;
    net.close(f.tcp as int);
}

fn server_of(f: Fake) -> Server { return Server { host: "127.0.0.1", port: f.port }; }

fn config_for(servers: [Server]) -> Config {
    let c = default_config();
    c.servers = servers;
    c.timeout = ms(2000);
    c.attempts = 1;
    return c;
}

fn resolver_for(f: Fake) -> Resolver {
    return new_resolver(config_for([server_of(f)]), no_hosts());
}

fn sent(f: Fake) -> int {
    mutex_lock(f.mu);
    let n = f.queries;
    mutex_unlock(f.mu);
    return n;
}

// ---- addresses ------------------------------------------------------------

fn round_ip(s: str) -> str {
    let r = parse_ip(s);
    guard let b = r else { return "ERR"; }
    return format_ip(b);
}

fn test_ip_text_round_trips_to_canonical_form() {
    assert(round_ip("192.0.2.1") == "192.0.2.1");
    assert(round_ip("0.0.0.0") == "0.0.0.0");
    assert(round_ip("255.255.255.255") == "255.255.255.255");
    assert(round_ip("::") == "::");
    assert(round_ip("::1") == "::1");
    assert(round_ip("1::") == "1::");
    assert(round_ip("2001:0DB8::0001") == "2001:db8::1");
    // RFC 5952: the longest zero run, the first on a tie, never one group.
    assert(round_ip("2001:db8:0:0:1:0:0:1") == "2001:db8::1:0:0:1");
    assert(round_ip("1:0:0:2:0:0:0:3") == "1:0:0:2::3");
    assert(round_ip("2001:db8:0:1:1:1:1:1") == "2001:db8:0:1:1:1:1:1");
    assert(round_ip("::ffff:192.0.2.1") == "::ffff:c000:201");
    assert(round_ip("::192.0.2.1") == "::c000:201");
    assert(round_ip("1:2:3:4:5:6:1.2.3.4") == "1:2:3:4:5:6:102:304");
}

fn test_ip_parse_refuses_what_is_not_an_address() {
    for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.a", " 1.2.3.4",
                ":::", "1:::2", "1::2::3", "12345::", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9",
                ":1", "1:", "g::", "::1.2.3", "localhost"] {
        if let _b = parse_ip(bad) {
            assert(false, "parsed " + bad);
        }
    }
}

fn test_reverse_names() {
    assert((reverse_name("192.0.2.5") ?? "") == "5.2.0.192.in-addr.arpa");
    assert((reverse_name("2001:db8::567:89ab") ?? "") ==
           "b.a.9.8.7.6.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa");
    if let _r = reverse_name("nope") { assert(false, "reversed a non-address"); }
}

// ---- messages -------------------------------------------------------------

fn test_message_round_trips_every_record_type() {
    let mx = rec("Example.COM.", MX, 300, "mail.example.com");
    mx.priority = 10;
    let srv = rec("_imap._tcp.example.com", SRV, 300, "imap.example.com");
    srv.priority = 1;
    srv.weight = 5;
    srv.port = 993;
    let long_text = strings.repeat("x", 300);
    let m = Message { id: 4242, response: true, authoritative: true, truncated: false,
                      recursion_desired: true, recursion_available: true, rcode: NOERROR,
                      questions: [Question { name: "example.com", qtype: A }],
                      answers: [rec("example.com", A, 60, "192.0.2.1"),
                                rec("example.com", AAAA, 60, "2001:db8::1"),
                                rec("www.example.com", CNAME, 60, "example.com"),
                                mx, srv,
                                rec("example.com", TXT, 60, long_text),
                                rec("example.com", NS, 60, "ns1.example.com"),
                                rec("1.2.0.192.in-addr.arpa", PTR, 60, "example.com")],
                      authority: [rec("example.com", SOA, 900, "ns1.example.com")],
                      additional: [] };
    let er = encode(m);
    guard let wire = er else let e = err_of(er) { panic(e); }
    let dr = decode(wire);
    guard let back = dr else let e = err_of(dr) { panic(e); }
    assert(back.id == 4242 && back.response && back.authoritative && back.recursion_available);
    assert(!back.truncated && back.rcode == NOERROR);
    assert(len(back.questions) == 1 && back.questions[0].name == "example.com");
    assert(len(back.answers) == 8);
    assert(back.answers[0].value == "192.0.2.1" && back.answers[0].ttl == 60);
    assert(back.answers[1].value == "2001:db8::1");
    assert(back.answers[2].name == "www.example.com" && back.answers[2].value == "example.com");
    assert(back.answers[3].name == "example.com" && back.answers[3].priority == 10);
    assert(back.answers[4].port == 993 && back.answers[4].weight == 5 && back.answers[4].priority == 1);
    assert(back.answers[5].value == long_text);
    assert(back.answers[6].value == "ns1.example.com");
    assert(back.answers[7].rtype == PTR);
    assert(len(back.authority) == 1 && back.authority[0].ttl == 900);
}

fn test_soa_ttl_is_the_negative_ttl() {
    // A SOA record with TTL 3600 and MINIMUM 30: the negative TTL is 30.
    let b = builder.new_bytes();
    put16(b, 1); put16(b, 0x8180); put16(b, 0); put16(b, 0); put16(b, 1); put16(b, 0);
    b.write_byte(1); b.write_str("x"); b.write_byte(0);
    put16(b, SOA); put16(b, 1); put32(b, 3600);
    put16(b, 1 + 1 + 20);
    b.write_byte(0); b.write_byte(0);
    put32(b, 1); put32(b, 2); put32(b, 3); put32(b, 4); put32(b, 30);
    let dr = decode(b.finish());
    guard let m = dr else let e = err_of(dr) { panic(e); }
    assert(m.authority[0].ttl == 30);
}

fn query_with(name_bytes: bytes) -> bytes {
    let b = builder.new_bytes();
    put16(b, 7); put16(b, 0x8180); put16(b, 1); put16(b, 1); put16(b, 0); put16(b, 0);
    b.write(name_bytes);
    put16(b, A); put16(b, 1);
    return b.finish();
}

fn test_decode_follows_compression_pointers() {
    let b = builder.new_bytes();
    b.write(query_with(b"\x03www\x07Example\x03com\x00"));
    // The answer's name is a pointer to the question's (offset 12), and
    // a second record's name is "mail" + a pointer to "example.com".
    b.write(b"\xC0\x0C"); put16(b, A); put16(b, 1); put32(b, 60); put16(b, 4);
    b.write(b"\xC0\x00\x02\x01");
    let dr = decode(b.finish());
    guard let m = dr else let e = err_of(dr) { panic(e); }
    assert(m.answers[0].name == "www.example.com");
    assert(m.answers[0].value == "192.0.2.1");
}

fn decode_fails(b: bytes) -> bool {
    if let _m = decode(b) { return false; }
    return true;
}

fn test_decode_refuses_malformed_messages() {
    assert(decode_fails(b""));
    assert(decode_fails(b"\x00\x01\x81\x80\x00\x01"));
    // A pointer to itself, and a pointer forward.
    assert(decode_fails(query_with(b"\xC0\x0C")));
    assert(decode_fails(query_with(b"\xC0\x20")));
    // A label type this decoder does not know (0x40), and a label that
    // runs off the end.
    assert(decode_fails(query_with(b"\x40abc\x00")));
    assert(decode_fails(b"\x00\x07\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00\x09ab"));
    // A NUL inside a label, and a dot inside one.
    assert(decode_fails(query_with(b"\x03a\x00b\x00")));
    assert(decode_fails(query_with(b"\x03a.b\x00")));
    // An answer count with no answers behind it.
    let b = builder.new_bytes();
    put16(b, 7); put16(b, 0x8180); put16(b, 0); put16(b, 1); put16(b, 0); put16(b, 0);
    assert(decode_fails(b.finish()));
    // More records than any honest message carries.
    let c = builder.new_bytes();
    put16(c, 7); put16(c, 0x8180); put16(c, 0); put16(c, 65535); put16(c, 0); put16(c, 0);
    assert(decode_fails(c.finish()));
    // An A record that is not 4 bytes.
    let d = builder.new_bytes();
    d.write(query_with(b"\x01a\x00"));
    d.write(b"\xC0\x0C"); put16(d, A); put16(d, 1); put32(d, 60); put16(d, 3); d.write(b"\x01\x02\x03");
    assert(decode_fails(d.finish()));
}

fn test_a_long_compressed_name_is_refused() {
    // 130 one-byte labels, each a pointer chain back: over 255 bytes.
    let b = builder.new_bytes();
    put16(b, 7); put16(b, 0x8180); put16(b, 1); put16(b, 0); put16(b, 0); put16(b, 0);
    let i = 0;
    while i < 130 { b.write(b"\x01a"); i = i + 1; }
    b.write_byte(0);
    put16(b, A); put16(b, 1);
    assert(decode_fails(b.finish()));
}

fn test_encode_query_refuses_bad_names() {
    for bad in ["a..b", strings.repeat("a", 64) + ".com", "has space.com", "tab\t.com",
                strings.repeat("abcdefgh.", 29) + "com"] {
        if let _q = encode_query(1, bad, A) { assert(false, "encoded " + bad); }
    }
    let ok1 = encode_query(1, "_sip._udp.example.com.", SRV);
    guard let q = ok1 else let e = err_of(ok1) { panic(e); }
    let dr = decode(q);
    guard let m = dr else let e = err_of(dr) { panic(e); }
    assert(m.questions[0].name == "_sip._udp.example.com" && m.questions[0].qtype == SRV);
    assert(m.recursion_desired && !m.response);
}

// ---- configuration --------------------------------------------------------

fn test_resolv_conf_is_read_like_glibc() {
    let c = parse_resolv_conf("# comment\n" +
        "nameserver 10.0.0.2\n" +
        "nameserver\tfe80::1%eth0   ; zone kept\n" +
        "nameserver not-an-ip\n" +
        "search Corp.Example. lab.example\n" +
        "options ndots:3 timeout:2 attempts:9 rotate\n");
    assert(len(c.servers) == 2);
    assert(c.servers[0].host == "10.0.0.2" && c.servers[0].port == 53);
    assert(c.servers[1].host == "fe80::1%eth0");
    assert(len(c.search) == 2 && c.search[0] == "corp.example" && c.search[1] == "lab.example");
    assert(c.ndots == 3 && c.timeout == 2000000000 && c.attempts == 5 && c.rotate);
    let d = parse_resolv_conf("domain example.org\noptions ndots:99 timeout:0\n");
    assert(len(d.search) == 1 && d.search[0] == "example.org");
    assert(d.ndots == 15 && d.timeout == 1000000000);
    // No usable server: the local host, as glibc does.
    assert(len(d.servers) == 2 && d.servers[0].host == "127.0.0.1");
}

fn test_hosts_file_is_read() {
    let h = parse_hosts("127.0.0.1 localhost\n" +
        "10.0.0.5  db.internal  DB  # the database\n" +
        "2001:DB8::5 db.internal.\n" +
        "300.1.1.1 broken\n" +
        "# 10.0.0.9 commented\n");
    assert(len(h.by_name["db.internal"]) == 2);
    assert(h.by_name["db.internal"][1] == "2001:db8::5");
    assert(h.by_name["db"][0] == "10.0.0.5");
    assert(!has(h.by_name, "broken") && !has(h.by_name, "commented"));
}

// ---- the resolver ---------------------------------------------------------

fn test_lookup_ip_asks_for_both_families_and_caches() {
    let f = fake();
    add(f, rec("api.test", A, 60, "192.0.2.10"));
    add(f, rec("api.test", AAAA, 60, "2001:db8::10"));
    let r = resolver_for(f);
    let lr = lookup_ip(r, "API.test", soon());
    guard let ips = lr else let e = err_of(lr) { panic(e); }
    assert(len(ips) == 2 && ips[0] == "192.0.2.10" && ips[1] == "2001:db8::10");
    assert(queries_sent(r) == 2 && sent(f) == 2);
    let again = lookup_ip(r, "api.test.", soon()) ?? [];
    assert(len(again) == 2);
    assert(queries_sent(r) == 2 && sent(f) == 2);
    assert(cache_len(r) == 2);
    stop(f);
}

fn test_one_family_is_enough() {
    let f = fake();
    add(f, rec("v4only.test", A, 60, "192.0.2.4"));
    let r = resolver_for(f);
    let ips = lookup_ip(r, "v4only.test", soon()) ?? [];
    assert(len(ips) == 1 && ips[0] == "192.0.2.4");
    let lr = lookup(r, "v4only.test", AAAA, soon());
    guard let none_here = lr else let e = err_of(lr) { panic(e); }
    assert(len(none_here) == 0);
    stop(f);
}

fn test_ttl_bounds_the_cache() {
    let f = fake();
    add(f, rec("short.test", A, 1, "192.0.2.1"));
    add(f, rec("zero.test", A, 0, "192.0.2.2"));
    let r = resolver_for(f);
    let _a = lookup(r, "short.test", A, soon());
    let _b = lookup(r, "short.test", A, soon());
    assert(sent(f) == 1);
    time.sleep(ms(1100));
    let _c = lookup(r, "short.test", A, soon());
    assert(sent(f) == 2);
    // TTL 0: never cached.
    let _d = lookup(r, "zero.test", A, soon());
    let _e = lookup(r, "zero.test", A, soon());
    assert(sent(f) == 4);
    stop(f);
}

fn test_max_ttl_caps_a_long_ttl() {
    let f = fake();
    add(f, rec("long.test", A, 86400, "192.0.2.1"));
    let r = resolver_for(f);
    r.max_ttl = 1;
    let _a = lookup(r, "long.test", A, soon());
    time.sleep(ms(1100));
    let _b = lookup(r, "long.test", A, soon());
    assert(sent(f) == 2);
    stop(f);
}

fn test_nxdomain_is_no_such_host_and_cached_by_the_soa() {
    let f = fake();
    f.nx["gone.test"] = true;
    f.soa = some(rec("test", SOA, 30, "ns.test"));
    let r = resolver_for(f);
    let lr = lookup(r, "gone.test", A, soon());
    if let _x = lr { assert(false, "found a name that does not exist"); } else let e = err_of(lr) {
        assert(e == "no such host", e);
    }
    let _again = lookup(r, "gone.test", A, soon());
    assert(sent(f) == 1);
    let ir = lookup_ip(r, "gone.test", soon());
    if let _y = ir { assert(false, "lookup_ip found it"); } else let e = err_of(ir) {
        assert(e == "no such host", e);
    }
    stop(f);
}

fn test_a_negative_answer_without_a_soa_is_not_cached() {
    let f = fake();
    f.nx["gone.test"] = true;
    let r = resolver_for(f);
    let _a = lookup(r, "gone.test", A, soon());
    let _b = lookup(r, "gone.test", A, soon());
    assert(sent(f) == 2);
    stop(f);
}

fn test_search_domains_and_ndots() {
    let f = fake();
    add(f, rec("db.corp.test", A, 60, "10.1.1.1"));
    add(f, rec("db", A, 60, "10.9.9.9"));
    add(f, rec("x.y", A, 60, "10.2.2.2"));
    add(f, rec("x.y.corp.test", A, 60, "10.3.3.3"));
    f.nx["only.corp.test"] = true;
    add(f, rec("only", A, 60, "10.4.4.4"));
    let cfg = config_for([server_of(f)]);
    cfg.search = ["corp.test"];
    cfg.ndots = 1;
    let r = new_resolver(cfg, no_hosts());
    // Fewer dots than ndots: the search domain first.
    assert((lookup_ip(r, "db", soon()) ?? [])[0] == "10.1.1.1");
    // As many as ndots: the name as it is first.
    assert((lookup_ip(r, "x.y", soon()) ?? [])[0] == "10.2.2.2");
    // A final dot: only the name itself.
    assert((lookup_ip(r, "db.", soon()) ?? [])[0] == "10.9.9.9");
    // NXDOMAIN under the search domain moves on to the bare name.
    assert((lookup_ip(r, "only", soon()) ?? [])[0] == "10.4.4.4");
    stop(f);
}

fn test_cname_chains_are_followed() {
    let f = fake();
    add(f, rec("www.test", CNAME, 60, "web.test"));
    add(f, rec("web.test", CNAME, 60, "origin.test"));
    add(f, rec("origin.test", A, 60, "192.0.2.80"));
    let r = resolver_for(f);
    let lr = lookup(r, "www.test", A, soon());
    guard let recs = lr else let e = err_of(lr) { panic(e); }
    assert(len(recs) == 1 && recs[0].value == "192.0.2.80" && recs[0].name == "origin.test");
    assert((lookup_cname(r, "www.test", soon()) ?? "") == "origin.test");
    assert((lookup_cname(r, "origin.test", soon()) ?? "") == "origin.test");
    let cr = lookup(r, "www.test", CNAME, soon());
    guard let cn = cr else let e = err_of(cr) { panic(e); }
    assert(len(cn) == 1 && cn[0].value == "web.test");
    stop(f);
}

fn test_a_cname_that_leaves_the_answer_is_queried() {
    let f = fake();
    f.no_chase = true;
    add(f, rec("www.test", CNAME, 60, "elsewhere.test"));
    add(f, rec("elsewhere.test", A, 60, "192.0.2.81"));
    let r = resolver_for(f);
    let ips = lookup_ip(r, "www.test", soon()) ?? [];
    assert(len(ips) == 1 && ips[0] == "192.0.2.81");
    stop(f);
}

fn test_a_cname_loop_is_an_error() {
    let f = fake();
    f.no_chase = true;
    add(f, rec("a.test", CNAME, 60, "b.test"));
    add(f, rec("b.test", CNAME, 60, "a.test"));
    let r = resolver_for(f);
    let lr = lookup(r, "a.test", A, soon());
    if let _x = lr { assert(false, "a loop resolved"); } else let e = err_of(lr) {
        assert(strings.contains(e, "CNAME chain"), e);
    }
    stop(f);
}

fn test_a_truncated_answer_is_asked_again_over_tcp() {
    let f = fake();
    f.truncate = true;
    let i = 0;
    while i < 40 {
        add(f, rec("big.test", TXT, 60, strings.repeat("t", 100) + to_str(i)));
        i = i + 1;
    }
    let r = resolver_for(f);
    let lr = lookup_txt(r, "big.test", soon());
    guard let txt = lr else let e = err_of(lr) { panic(e); }
    assert(len(txt) == 40);
    assert(f.tcp_queries == 1);
    stop(f);
}

fn test_a_reply_with_the_wrong_id_is_ignored() {
    let f = fake();
    f.spoof_first = true;
    add(f, rec("bank.test", A, 60, "192.0.2.7"));
    let r = resolver_for(f);
    let ips = lookup_ip(r, "bank.test", soon()) ?? [];
    assert(len(ips) == 1 && ips[0] == "192.0.2.7");
    stop(f);
}

fn test_garbage_before_the_answer_is_ignored() {
    let f = fake();
    f.garbage_first = true;
    add(f, rec("noisy.test", A, 60, "192.0.2.8"));
    let r = resolver_for(f);
    let ips = lookup_ip(r, "noisy.test", soon()) ?? [];
    assert(len(ips) == 1 && ips[0] == "192.0.2.8");
    stop(f);
}

fn test_servfail_moves_on_to_the_next_server() {
    let bad = fake();
    bad.servfail = true;
    let good = fake();
    add(good, rec("svc.test", A, 60, "192.0.2.9"));
    let r = new_resolver(config_for([server_of(bad), server_of(good)]), no_hosts());
    let lr = lookup(r, "svc.test", A, soon());
    guard let recs = lr else let e = err_of(lr) { panic(e); }
    assert(recs[0].value == "192.0.2.9");
    assert(sent(bad) == 1 && sent(good) == 1);
    // Every server failing is an error naming the rcode.
    let only_bad = new_resolver(config_for([server_of(bad)]), no_hosts());
    let br = lookup(only_bad, "svc.test", A, soon());
    if let _x = br { assert(false, "SERVFAIL resolved"); } else let e = err_of(br) {
        assert(strings.contains(e, "rcode 2"), e);
    }
    stop(bad);
    stop(good);
}

fn test_a_silent_server_costs_one_try_then_the_next_answers() {
    let quiet = fake();
    quiet.silent = true;
    let good = fake();
    add(good, rec("svc.test", A, 60, "192.0.2.9"));
    let cfg = config_for([server_of(quiet), server_of(good)]);
    cfg.timeout = ms(150);
    let r = new_resolver(cfg, no_hosts());
    let t0 = time.mono() as int;
    let lr = lookup(r, "svc.test", A, soon());
    let took = (time.mono() as int) - t0;
    guard let recs = lr else let e = err_of(lr) { panic(e); }
    assert(recs[0].value == "192.0.2.9");
    assert(took >= ms(140) && took < ms(1500), to_str(took));
    stop(quiet);
    stop(good);
}

fn test_the_callers_deadline_wins_over_the_per_try_timeout() {
    let quiet = fake();
    quiet.silent = true;
    let cfg = config_for([server_of(quiet)]);
    cfg.timeout = ms(5000);
    cfg.attempts = 3;
    let r = new_resolver(cfg, no_hosts());
    let t0 = time.mono() as int;
    let lr = lookup(r, "svc.test", A, until_of(time.mono() + ms(200)));
    let took = (time.mono() as int) - t0;
    if let _x = lr { assert(false, "a silent server answered"); } else let e = err_of(lr) {
        assert(e == "timeout", e);
    }
    assert(took >= ms(190) && took < ms(1500), to_str(took));
    stop(quiet);
}

fn test_rotate_spreads_queries_over_servers() {
    let a = fake();
    let b = fake();
    add(a, rec("r.test", A, 0, "192.0.2.1"));
    add(b, rec("r.test", A, 0, "192.0.2.1"));
    let cfg = config_for([server_of(a), server_of(b)]);
    cfg.rotate = true;
    let r = new_resolver(cfg, no_hosts());
    let i = 0;
    while i < 4 {
        let _l = lookup(r, "r.test", A, soon());
        i = i + 1;
    }
    assert(sent(a) == 2 && sent(b) == 2);
    stop(a);
    stop(b);
}

fn test_hosts_literals_and_localhost_need_no_query() {
    let f = fake();
    let r = new_resolver(config_for([server_of(f)]),
                         parse_hosts("10.0.0.5 db.internal\n::1 v6.internal\n"));
    assert((lookup_ip(r, "DB.internal", soon()) ?? [])[0] == "10.0.0.5");
    let copy = lookup_ip(r, "db.internal", soon()) ?? [];
    push(copy, "changed");
    assert(len(lookup_ip(r, "db.internal", soon()) ?? []) == 1);
    assert((lookup_ip(r, "v6.internal", soon()) ?? [])[0] == "::1");
    assert((lookup_ip(r, "192.0.2.1", soon()) ?? [])[0] == "192.0.2.1");
    assert((lookup_ip(r, "[2001:DB8::1]", soon()) ?? [])[0] == "2001:db8::1");
    let lh = lookup_ip(r, "localhost", soon()) ?? [];
    assert(len(lh) == 2 && lh[0] == "127.0.0.1" && lh[1] == "::1");
    assert(len(lookup_ip(r, "app.localhost", soon()) ?? []) == 2);
    assert(sent(f) == 0);
    stop(f);
}

fn test_mx_srv_txt_ns_and_ptr() {
    let f = fake();
    let m1 = rec("example.test", MX, 60, "backup.example.test");
    m1.priority = 20;
    let m2 = rec("example.test", MX, 60, "mail.example.test");
    m2.priority = 10;
    add(f, m1);
    add(f, m2);
    let s1 = rec("_x._tcp.example.test", SRV, 60, "light.example.test");
    s1.priority = 1; s1.weight = 10; s1.port = 8001;
    let s2 = rec("_x._tcp.example.test", SRV, 60, "heavy.example.test");
    s2.priority = 1; s2.weight = 90; s2.port = 8002;
    let s3 = rec("_x._tcp.example.test", SRV, 60, "fallback.example.test");
    s3.priority = 5; s3.weight = 100; s3.port = 8003;
    add(f, s3);
    add(f, s1);
    add(f, s2);
    add(f, rec("example.test", TXT, 60, "v=spf1 -all"));
    add(f, rec("example.test", NS, 60, "ns1.example.test"));
    add(f, rec("9.2.0.192.in-addr.arpa", PTR, 60, "host.example.test"));
    let r = resolver_for(f);
    let mx = lookup_mx(r, "example.test", soon()) ?? [];
    assert(len(mx) == 2 && mx[0].value == "mail.example.test" && mx[1].priority == 20);
    let srv = lookup_srv(r, "_x._tcp.example.test", soon()) ?? [];
    assert(len(srv) == 3);
    assert(srv[0].port == 8002 && srv[1].port == 8001 && srv[2].port == 8003);
    assert((lookup_txt(r, "example.test", soon()) ?? [])[0] == "v=spf1 -all");
    assert((lookup_ns(r, "example.test", soon()) ?? [])[0] == "ns1.example.test");
    assert((lookup_addr(r, "192.0.2.9", soon()) ?? [])[0] == "host.example.test");
    stop(f);
}

fn test_the_cache_stays_bounded() {
    let f = fake();
    let names = ["a.test", "b.test", "c.test", "d.test"];
    for n in names { add(f, rec(n, A, 60, "192.0.2.1")); }
    let r = resolver_for(f);
    r.max_entries = 2;
    for n in names { let _l = lookup(r, n, A, soon()); }
    assert(cache_len(r) <= 2);
    cache_clear(r);
    assert(cache_len(r) == 0);
    stop(f);
}

fn test_a_bad_name_fails_before_any_query() {
    let f = fake();
    let r = resolver_for(f);
    if let _x = lookup(r, "a..test", A, soon()) { assert(false, "looked up a bad name"); }
    assert(sent(f) == 0);
    stop(f);
}
