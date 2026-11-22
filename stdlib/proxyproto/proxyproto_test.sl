import "net";
import "strings";
import "time";

fn must(r: result[opt[Header], str]) -> Header {
    guard let o = r else let e = err_of(r) { panic("unexpected error: " + e); }
    guard let h = o else { panic("unexpected none"); }
    return h;
}

fn must_fail(r: result[opt[Header], str]) -> str {
    if let _o = r { panic("expected an error"); }
    return err_of(r);
}

fn is_none(r: result[opt[Header], str]) -> bool {
    guard let o = r else { return false; }
    if let _h = o { return false; }
    return true;
}

fn hdr(family: str, sa: str, sp: int, da: str, dp: int) -> Header {
    return Header { version: 2, local: false, family: family, src_addr: sa,
                    src_port: sp, dst_addr: da, dst_port: dp, tlvs: [],
                    size: 0, rest: b"" };
}

// ---- v1 -------------------------------------------------------------------

fn test_should_parse_v1_tcp4_and_report_its_size() {
    let h = must(parse(b"PROXY TCP4 192.0.2.1 198.51.100.2 56324 443\r\nGET / HTTP/1.1"));
    assert(h.version == 1 && h.family == "tcp4", "family");
    assert(h.src_addr == "192.0.2.1" && h.src_port == 56324, "source");
    assert(h.dst_addr == "198.51.100.2" && h.dst_port == 443, "destination");
    assert(h.size == 45, "size " + to_str(h.size));
}

fn test_should_parse_v1_tcp6_and_unknown() {
    let h = must(parse(b"PROXY TCP6 2001:db8::1 ::1 1 65535\r\n"));
    assert(h.family == "tcp6" && h.src_addr == "2001:db8::1" && h.dst_port == 65535, "tcp6");
    let u = must(parse(b"PROXY UNKNOWN ffff::1 ffff::2 1 2\r\n"));
    assert(u.family == "unknown" && u.src_addr == "", "unknown");
}

fn test_should_return_none_for_every_prefix_of_a_v1_header() {
    let full = b"PROXY TCP4 10.0.0.1 10.0.0.2 1000 2000\r\n";
    for i in 0..len(full) {
        assert(is_none(parse(full[0..i])), "prefix " + to_str(i));
    }
}

fn test_should_reject_malformed_v1() {
    must_fail(parse(b"GET / HTTP/1.1\r\n"));
    must_fail(parse(b"PROXY TCP4 10.0.0.1 10.0.0.2 1000\r\n"));
    must_fail(parse(b"PROXY TCP4 10.0.0.256 10.0.0.2 1000 2000\r\n"));
    must_fail(parse(b"PROXY TCP4 10.0.0.1 10.0.0.2 1000 70000\r\n"));
    must_fail(parse(b"PROXY TCP4 10.0.0.1 10.0.0.2 01000 2000\r\n"));
    must_fail(parse(b"PROXY TCP4 10.0.0.1 10.0.0.2 1000 2000\n"));
    must_fail(parse(b"PROXY TCP9 10.0.0.1 10.0.0.2 1000 2000\r\n"));
    must_fail(parse(b"PROXY TCP6 10.0.0.1 10.0.0.2 1000 2000\r\n"));
    let long = b"PROXY UNKNOWN " + to_bytes(strings.repeat("x", 120));
    let e = must_fail(parse(long));
    assert(strings.contains(e, "too long"), e);
}

// ---- v2 -------------------------------------------------------------------

fn round_trip(h: Header) -> Header {
    let er = encode_v2(h);
    guard let b = er else let e = err_of(er) { panic("encode: " + e); }
    let back = must(parse(b + b"payload"));
    assert(back.size == len(b), "size");
    return back;
}

fn test_should_round_trip_v2_for_every_family() {
    let a = round_trip(hdr("tcp4", "192.0.2.1", 56324, "198.51.100.2", 443));
    assert(a.family == "tcp4" && a.src_addr == "192.0.2.1" && a.src_port == 56324 &&
           a.dst_addr == "198.51.100.2" && a.dst_port == 443, "tcp4");
    let b = round_trip(hdr("udp6", "2001:db8:0:0:1:0:0:1", 53, "::ffff:192.0.2.9", 5353));
    assert(b.family == "udp6" && b.src_addr == "2001:db8::1:0:0:1" &&
           b.dst_addr == "::ffff:c000:209", "udp6 " + b.src_addr + " " + b.dst_addr);
    let c = round_trip(hdr("unix", "/run/client.sock", 0, "/run/server.sock", 0));
    assert(c.family == "unix" && c.src_addr == "/run/client.sock" &&
           c.dst_addr == "/run/server.sock", "unix");
    let d = round_trip(hdr("unknown", "", 0, "", 0));
    assert(d.family == "unknown" && d.size == 16, "unspec");
}

fn test_should_mark_local_and_drop_its_addresses() {
    let h = hdr("tcp4", "10.0.0.1", 1, "10.0.0.2", 2);
    h.local = true;
    let l = round_trip(h);
    assert(l.local && l.family == "unknown" && l.src_addr == "", "local");
}

fn test_should_carry_tlvs() {
    let h = hdr("tcp4", "10.0.0.1", 1, "10.0.0.2", 2);
    h.tlvs = [Tlv { kind: 0x02, value: b"example.com" }, Tlv { kind: 0xEA, value: b"\x01vpce-123" },
              Tlv { kind: 0x05, value: b"" }];
    let t = round_trip(h);
    assert(len(t.tlvs) == 3, "count");
    assert(t.tlvs[0].kind == 2 && t.tlvs[0].value == b"example.com", "authority");
    assert(t.tlvs[1].kind == 0xEA && t.tlvs[1].value == b"\x01vpce-123", "aws");
    assert(t.tlvs[2].kind == 5 && len(t.tlvs[2].value) == 0, "empty value");
}

// The example in the HAProxy specification's style, built by hand: a
// TCP over IPv4 PROXY command with one NOOP TLV.
fn test_should_parse_hand_built_v2_bytes() {
    let b = b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A\x21\x11\x00\x10" +
            b"\x7F\x00\x00\x01\xC0\xA8\x01\x02\x30\x39\x01\xBB" + b"\x04\x00\x01\xAA";
    let h = must(parse(b));
    assert(h.src_addr == "127.0.0.1" && h.src_port == 12345, "source");
    assert(h.dst_addr == "192.168.1.2" && h.dst_port == 443, "destination");
    assert(len(h.tlvs) == 1 && h.tlvs[0].kind == 4 && h.tlvs[0].value == b"\xAA", "noop tlv");
}

fn test_should_return_none_for_every_prefix_of_a_v2_header() {
    let h = hdr("tcp6", "2001:db8::1", 1, "2001:db8::2", 2);
    h.tlvs = [Tlv { kind: 1, value: b"h2" }];
    let full = encode_v2(h) ?? b"";
    for i in 0..len(full) {
        assert(is_none(parse(full[0..i])), "prefix " + to_str(i));
    }
}

fn test_should_reject_malformed_v2() {
    let sig = b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A";
    must_fail(parse(b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0B"));
    must_fail(parse(sig + b"\x11\x11\x00\x00"));               // version 1 in a v2 header
    must_fail(parse(sig + b"\x22\x11\x00\x00"));               // command 2
    must_fail(parse(sig + b"\x21\x11\x00\x04\x01\x02\x03\x04")); // IPv4 block too short
    must_fail(parse(sig + b"\x21\x51\x00\x00"));               // family 5
    must_fail(parse(sig + b"\x21\x00\x00\x02\x01\x00"));       // truncated TLV header
    must_fail(parse(sig + b"\x21\x00\x00\x04\x01\x00\x05\x00")); // TLV longer than the block
}

fn test_should_refuse_to_encode_mismatched_addresses() {
    if let _b = encode_v2(hdr("tcp4", "2001:db8::1", 1, "10.0.0.1", 2)) { panic("v6 in tcp4"); }
    if let _c = encode_v2(hdr("tcp6", "10.0.0.1", 1, "::1", 2)) { panic("v4 in tcp6"); }
    if let _d = encode_v2(hdr("tcp4", "10.0.0.1", 70000, "10.0.0.2", 2)) { panic("port"); }
    if let _e = encode_v2(hdr("sctp", "10.0.0.1", 1, "10.0.0.2", 2)) { panic("family"); }
}

fn test_should_format_ipv6_per_rfc_5952() {
    let cases = [["2001:0db8:0000:0000:0000:0000:0000:0001", "2001:db8::1"],
                 ["0:0:0:0:0:0:0:1", "::1"], ["::", "::"], ["fe80::", "fe80::"],
                 ["2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"],
                 ["2001:0:0:1:0:0:0:1", "2001:0:0:1::1"],
                 ["2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"],
                 ["::ffff:10.1.2.3", "::ffff:a01:203"]];
    for c in cases {
        let b = parse_ip6(c[0]);
        assert(len(b) == 16, "parse " + c[0]);
        assert(fmt_ip6(b, 0) == c[1], c[0] + " -> " + fmt_ip6(b, 0));
    }
    for bad in ["1::2::3", "12345::", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "g::1", ":::"] {
        assert(len(parse_ip6(bad)) == 0, "accepted " + bad);
    }
}

fn test_should_encode_v1() {
    let h = hdr("tcp4", "10.0.0.1", 1000, "10.0.0.2", 80);
    assert(encode_v1(h) == b"PROXY TCP4 10.0.0.1 10.0.0.2 1000 80\r\n", "tcp4");
    assert(encode_v1(hdr("unix", "/a", 0, "/b", 0)) == b"PROXY UNKNOWN\r\n", "unknown");
    let back = must(parse(encode_v1(hdr("tcp6", "::1", 1, "::2", 2))));
    assert(back.src_addr == "::1" && back.dst_port == 2, "v1 round trip");
}

// ---- read_until -----------------------------------------------------------

fn send_split(fd: i32, a: bytes, b: bytes) {
    let _x = net.send(fd, a);
    time.sleep(20000000);
    let _y = net.send(fd, b);
}

fn test_should_read_a_split_header_and_keep_the_bytes_after_it() {
    let lfd = net.listen(0) ?? -1;
    let port = net.port(lfd) ?? 0;
    let c = net.dial("127.0.0.1", port) ?? -1;
    let s = net.accept(lfd) ?? -1;
    let h = hdr("tcp4", "203.0.113.7", 41000, "10.0.0.5", 8080);
    let wire = (encode_v2(h) ?? b"") + b"GET / HTTP/1.1\r\n";
    spawn send_split(c, wire[0..10], wire[10..]);
    let rr = read_until(s, until_of(time.mono() + 5000000000));
    guard let got = rr else let e = err_of(rr) { panic("read_until: " + e); }
    assert(got.src_addr == "203.0.113.7" && got.src_port == 41000, "address");
    // the application's bytes may still be on their way: read the rest
    let rest = got.rest;
    while len(rest) < 16 {
        let more = net.recv_until(s, 64, until_of(time.mono() + 5000000000)) ?? b"";
        if len(more) == 0 { break; }
        rest = rest + more;
    }
    assert(rest == b"GET / HTTP/1.1\r\n", "rest " + to_str(rest));
    net.close(c);
    net.close(s);
    net.close(lfd);
}

fn test_should_fail_read_until_on_a_direct_client() {
    let lfd = net.listen(0) ?? -1;
    let port = net.port(lfd) ?? 0;
    let c = net.dial("127.0.0.1", port) ?? -1;
    let s = net.accept(lfd) ?? -1;
    let _x = net.send(c, b"GET / HTTP/1.1\r\n\r\n");
    let rr = read_until(s, until_of(time.mono() + 5000000000));
    if let _h = rr { panic("accepted a request without a header"); }
    assert(strings.contains(err_of(rr), "not a PROXY"), err_of(rr));
    net.close(c);
    net.close(s);
    net.close(lfd);
}
