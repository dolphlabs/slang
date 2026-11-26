// The PROXY protocol (HAProxy, versions 1 and 2): the header a load
// balancer such as HAProxy, AWS NLB or Cloudflare Spectrum puts in front
// of a connection, so the server sees the real client address instead of
// the balancer's.
//
//     import "proxyproto";
//
//     guard let h = proxyproto.read_until(fd, deadline) else |e| { net.close(fd); return; }
//     println(h.src_addr + ":" + to_str(h.src_port));   // the real client
//     // h.rest holds bytes that came after the header: the start of the
//     // application's stream, to be handled before reading more.
//
// Trust: the header is just bytes the peer sent. Accept it only on a
// listener that the balancer alone can reach (or after checking the
// peer's address); otherwise any client can claim any address.
//
// A v2 LOCAL header (a balancer's health check) has local = true and no
// addresses: use the connection's own.

import "builder";
import "net";
import "strings";

// One v2 type-length-value field: ALPN (0x01), authority (0x02, the TLS
// SNI name), unique id (0x05), SSL details (0x20), AWS VPC endpoint id
// (0xEA), and so on.
pub struct Tlv {
    kind: int,
    value: bytes,
}

pub struct Header {
    version: int,       // 1 or 2
    local: bool,        // v2 LOCAL: a health check, no addresses
    family: str,        // "tcp4", "tcp6", "udp4", "udp6", "unix", "unknown"
    src_addr: str,
    src_port: int,
    dst_addr: str,
    dst_port: int,
    tlvs: [Tlv],
    size: int,          // the header's length in bytes
    rest: bytes,        // read_until only: bytes after the header
}

// The largest header: v2's 16 fixed bytes plus a 16-bit length.
let MAX_V2 = 65551;
// v1's limit from the spec, CRLF included.
let MAX_V1 = 107;

// The header at the start of b; none if b is a prefix of one and more
// bytes are needed; an error if b does not start with a PROXY header.
pub fn parse(b: bytes) -> result[opt[Header], str] {
    if len(b) == 0 {
        return ok(none);
    }
    if b[0] == 0x0D {
        return parse_v2(b);
    }
    if b[0] == 0x50 {
        return parse_v1(b);
    }
    return err("proxyproto: not a PROXY protocol header");
}

// Reads a header from fd, then stops: whatever arrived after it is in
// rest. Bounded by deadline as a whole.
pub fn read_until(fd: i32, deadline: until) -> result[Header, str] {
    let buf = b"";
    while true {
        let pr = parse(buf);
        guard let found = pr else let e = err_of(pr) { return err(e); }
        if let h = found {
            h.rest = buf[h.size..];
            return ok(h);
        }
        let rr = net.recv_until(fd, 4096, deadline);
        guard let more = rr else let re = err_of(rr) { return err("proxyproto: " + re); }
        if len(more) == 0 {
            return err("proxyproto: connection closed inside the header");
        }
        buf = buf + more;
        if len(buf) > MAX_V2 {
            return err("proxyproto: header too long");
        }
    }
    return err("proxyproto: unreachable");
}

// The v1 (text) header for h: "PROXY TCP4 1.2.3.4 5.6.7.8 1111 443\r\n".
// Families other than tcp4 and tcp6 are sent as UNKNOWN.
pub fn encode_v1(h: Header) -> bytes {
    if h.family != "tcp4" && h.family != "tcp6" {
        return to_bytes("PROXY UNKNOWN\r\n");
    }
    return to_bytes("PROXY " + strings.to_upper(h.family) + " " + h.src_addr +
                    " " + h.dst_addr + " " + to_str(h.src_port) + " " +
                    to_str(h.dst_port) + "\r\n");
}

// The v2 (binary) header for h, TLVs included. An error for an address
// that does not match h.family.
pub fn encode_v2(h: Header) -> result[bytes, str] {
    let body = builder.new_bytes();
    let fam = 0x00;
    if !h.local {
        if h.family == "tcp4" || h.family == "udp4" {
            let s = parse_ip4(h.src_addr);
            let d = parse_ip4(h.dst_addr);
            if len(s) != 4 || len(d) != 4 { return err("proxyproto: bad IPv4 address"); }
            body.write(s);
            body.write(d);
            fam = 0x10;
        } else if h.family == "tcp6" || h.family == "udp6" {
            let s = parse_ip6(h.src_addr);
            let d = parse_ip6(h.dst_addr);
            if len(s) != 16 || len(d) != 16 { return err("proxyproto: bad IPv6 address"); }
            body.write(s);
            body.write(d);
            fam = 0x20;
        } else if h.family == "unix" {
            let s = to_bytes(h.src_addr);
            let d = to_bytes(h.dst_addr);
            if len(s) > 108 || len(d) > 108 { return err("proxyproto: unix path too long"); }
            body.write(s);
            for _ in len(s)..108 { body.write_byte(0); }
            body.write(d);
            for _ in len(d)..108 { body.write_byte(0); }
            fam = 0x30;
        } else if h.family != "unknown" {
            return err("proxyproto: unknown family " + h.family);
        }
        if fam == 0x10 || fam == 0x20 {
            if h.src_port < 0 || h.src_port > 65535 || h.dst_port < 0 || h.dst_port > 65535 {
                return err("proxyproto: port out of range");
            }
            body.write_byte(h.src_port >> 8);
            body.write_byte(h.src_port & 255);
            body.write_byte(h.dst_port >> 8);
            body.write_byte(h.dst_port & 255);
            if strings.has_prefix(h.family, "udp") { fam = fam | 0x02; } else { fam = fam | 0x01; }
        }
    }
    for t in h.tlvs {
        if t.kind < 0 || t.kind > 255 || len(t.value) > 65535 {
            return err("proxyproto: bad TLV");
        }
        body.write_byte(t.kind);
        body.write_byte(len(t.value) >> 8);
        body.write_byte(len(t.value) & 255);
        body.write(t.value);
    }
    let payload = body.finish();
    if len(payload) > 65535 {
        return err("proxyproto: header too long");
    }
    let out = builder.new_bytes();
    out.write(SIG2);
    if h.local { out.write_byte(0x20); } else { out.write_byte(0x21); }
    out.write_byte(fam);
    out.write_byte(len(payload) >> 8);
    out.write_byte(len(payload) & 255);
    out.write(payload);
    return ok(out.finish());
}

// ---- internals -----------------------------------------------------------

let SIG2 = b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A";

fn empty_header(version: int, size: int) -> Header {
    return Header {
        version: version, local: false, family: "unknown",
        src_addr: "", src_port: 0, dst_addr: "", dst_port: 0,
        tlvs: [], size: size, rest: b""
    };
}

fn parse_v1(b: bytes) -> result[opt[Header], str] {
    let sig = b"PROXY ";
    let n = len(b);
    let m = n;
    if m > len(sig) { m = len(sig); }
    for i in 0..m {
        if b[i] != sig[i] { return err("proxyproto: not a PROXY protocol header"); }
    }
    let end = -1;
    for i in 0..n {
        if i >= MAX_V1 { break; }
        if b[i] == 0x0A {
            end = i;
            break;
        }
    }
    if end < 0 {
        if n >= MAX_V1 { return err("proxyproto: v1 header too long"); }
        return ok(none);
    }
    if end == 0 || b[end - 1] != 0x0D {
        return err("proxyproto: v1 header without CRLF");
    }
    let line = to_str(b[0..end - 1]);
    let parts = strings.split(line, " ");
    let h = empty_header(1, end + 1);
    if len(parts) >= 2 && parts[1] == "UNKNOWN" {
        return ok(some(h));
    }
    if len(parts) != 6 {
        return err("proxyproto: malformed v1 header");
    }
    if parts[1] == "TCP4" {
        if len(parse_ip4(parts[2])) != 4 || len(parse_ip4(parts[3])) != 4 {
            return err("proxyproto: bad IPv4 address in v1 header");
        }
        h.family = "tcp4";
    } else if parts[1] == "TCP6" {
        if len(parse_ip6(parts[2])) != 16 || len(parse_ip6(parts[3])) != 16 {
            return err("proxyproto: bad IPv6 address in v1 header");
        }
        h.family = "tcp6";
    } else {
        return err("proxyproto: unknown v1 family " + parts[1]);
    }
    let sp = port_of(parts[4]);
    let dp = port_of(parts[5]);
    if sp < 0 || dp < 0 {
        return err("proxyproto: bad port in v1 header");
    }
    h.src_addr = parts[2];
    h.dst_addr = parts[3];
    h.src_port = sp;
    h.dst_port = dp;
    return ok(some(h));
}

fn parse_v2(b: bytes) -> result[opt[Header], str] {
    let n = len(b);
    let m = n;
    if m > 12 { m = 12; }
    for i in 0..m {
        if b[i] != SIG2[i] { return err("proxyproto: not a PROXY protocol header"); }
    }
    if n < 16 {
        return ok(none);
    }
    let ver = (b[12] as int) >> 4;
    let cmd = (b[12] as int) & 15;
    if ver != 2 {
        return err("proxyproto: unknown version " + to_str(ver));
    }
    if cmd > 1 {
        return err("proxyproto: unknown command " + to_str(cmd));
    }
    let size = 16 + ((b[14] as int) << 8 | (b[15] as int));
    if n < size {
        return ok(none);
    }
    let h = empty_header(2, size);
    h.local = cmd == 0;
    let af = (b[13] as int) >> 4;
    let proto = (b[13] as int) & 15;
    let at = 16;
    if af == 1 {
        if size < at + 12 { return err("proxyproto: v2 IPv4 block too short"); }
        h.src_addr = fmt_ip4(b, at);
        h.dst_addr = fmt_ip4(b, at + 4);
        h.src_port = u16_at(b, at + 8);
        h.dst_port = u16_at(b, at + 10);
        h.family = "tcp4";
        if proto == 2 { h.family = "udp4"; }
        at = at + 12;
    } else if af == 2 {
        if size < at + 36 { return err("proxyproto: v2 IPv6 block too short"); }
        h.src_addr = fmt_ip6(b, at);
        h.dst_addr = fmt_ip6(b, at + 16);
        h.src_port = u16_at(b, at + 32);
        h.dst_port = u16_at(b, at + 34);
        h.family = "tcp6";
        if proto == 2 { h.family = "udp6"; }
        at = at + 36;
    } else if af == 3 {
        if size < at + 216 { return err("proxyproto: v2 unix block too short"); }
        h.src_addr = cstr_at(b, at, 108);
        h.dst_addr = cstr_at(b, at + 108, 108);
        h.family = "unix";
        at = at + 216;
    } else if af != 0 {
        return err("proxyproto: unknown address family " + to_str(af));
    }
    if h.local {
        // LOCAL: the addresses (if any) mean nothing
        h.family = "unknown";
        h.src_addr = "";
        h.dst_addr = "";
        h.src_port = 0;
        h.dst_port = 0;
    }
    while at < size {
        if at + 3 > size { return err("proxyproto: truncated TLV"); }
        let kind = b[at] as int;
        let vl = u16_at(b, at + 1);
        if at + 3 + vl > size { return err("proxyproto: truncated TLV"); }
        push(h.tlvs, Tlv { kind: kind, value: b[at + 3..at + 3 + vl] });
        at = at + 3 + vl;
    }
    return ok(some(h));
}

fn u16_at(b: bytes, at: int) -> int {
    return (b[at] as int) << 8 | (b[at + 1] as int);
}

fn fmt_ip4(b: bytes, at: int) -> str {
    return to_str(b[at] as int) + "." + to_str(b[at + 1] as int) + "." +
           to_str(b[at + 2] as int) + "." + to_str(b[at + 3] as int);
}

let HEX = "0123456789abcdef";

fn hex_group(v: int) -> str {
    let s = "";
    let started = false;
    let shift = 12;
    while shift >= 0 {
        let d = (v >> shift) & 15;
        if d != 0 || started || shift == 0 {
            s = s + strings.slice(HEX, d, d + 1);
            started = true;
        }
        shift = shift - 4;
    }
    return s;
}

// RFC 5952 text: lower-case hex, leading zeros dropped, the longest run
// of two or more zero groups (the first, on a tie) as "::".
fn fmt_ip6(b: bytes, at: int) -> str {
    let g: [int] = [];
    for i in 0..8 {
        push(g, u16_at(b, at + 2 * i));
    }
    let best = -1;
    let best_len = 0;
    let i = 0;
    while i < 8 {
        if g[i] == 0 {
            let j = i;
            while j < 8 && g[j] == 0 { j = j + 1; }
            if j - i > best_len && j - i >= 2 {
                best = i;
                best_len = j - i;
            }
            i = j;
        } else {
            i = i + 1;
        }
    }
    let out = "";
    i = 0;
    while i < 8 {
        if i == best {
            out = out + "::";
            i = i + best_len;
            continue;
        }
        if len(out) > 0 && !strings.has_suffix(out, ":") {
            out = out + ":";
        }
        out = out + hex_group(g[i]);
        i = i + 1;
    }
    return out;
}

fn cstr_at(b: bytes, at: int, n: int) -> str {
    let end = at;
    while end < at + n && b[end] != 0 { end = end + 1; }
    return to_str(b[at..end]);
}

fn port_of(s: str) -> int {
    if len(s) == 0 || len(s) > 5 { return -1; }
    if len(s) > 1 && strings.has_prefix(s, "0") { return -1; }
    let v = to_int(s) ?? -1;
    if v < 0 || v > 65535 { return -1; }
    return v;
}

// Four bytes for a dotted IPv4 address, or empty.
fn parse_ip4(s: str) -> bytes {
    let out = builder.new_bytes();
    let parts = strings.split(s, ".");
    if len(parts) != 4 { return b""; }
    for p in parts {
        if len(p) == 0 || len(p) > 3 || (len(p) > 1 && strings.has_prefix(p, "0")) { return b""; }
        let v = to_int(p) ?? -1;
        if v < 0 || v > 255 { return b""; }
        out.write_byte(v);
    }
    return out.finish();
}

fn hex_val(c: str) -> int {
    if len(c) != 1 { return -1; }
    return strings.find(HEX, strings.to_lower(c));
}

// Sixteen bytes for an IPv6 address (with "::" and an embedded IPv4
// tail), or empty.
fn parse_ip6(s: str) -> bytes {
    let groups: [int] = [];
    let gap = -1;
    let head = s;
    let tail4 = b"";
    // an IPv4 tail ("::ffff:1.2.3.4")
    if strings.contains(s, ".") {
        let k = strings.rfind(s, ":");
        if k < 0 { return b""; }
        tail4 = parse_ip4(strings.slice(s, k + 1, len(s)));
        if len(tail4) != 4 { return b""; }
        head = strings.slice(s, 0, k + 1);
        if strings.has_suffix(head, "::") {
            // "::1.2.3.4"-style: keep the gap marker
        } else {
            head = strings.slice(head, 0, len(head) - 1);
        }
    }
    let dbl = strings.find(head, "::");
    if dbl >= 0 && strings.find(strings.slice(head, dbl + 1, len(head)), "::") >= 0 {
        return b"";
    }
    let left = head;
    let right = "";
    if dbl >= 0 {
        left = strings.slice(head, 0, dbl);
        right = strings.slice(head, dbl + 2, len(head));
    }
    let lg = ip6_groups(left);
    let rg = ip6_groups(right);
    if (len(left) > 0 && len(lg) == 0) || (len(right) > 0 && len(rg) == 0) { return b""; }
    let want = 8;
    if len(tail4) == 4 { want = 6; }
    let have = len(lg) + len(rg);
    if dbl < 0 && have != want { return b""; }
    if dbl >= 0 && have > want - 1 { return b""; }
    for x in lg { push(groups, x); }
    if dbl >= 0 {
        for _ in 0..want - have { push(groups, 0); }
    }
    for x in rg { push(groups, x); }
    let out = builder.new_bytes();
    for x in groups {
        out.write_byte(x >> 8);
        out.write_byte(x & 255);
    }
    out.write(tail4);
    let r = out.finish();
    if len(r) != 16 { return b""; }
    return r;
}

fn ip6_groups(s: str) -> [int] {
    let out: [int] = [];
    if len(s) == 0 { return out; }
    for p in strings.split(s, ":") {
        if len(p) == 0 || len(p) > 4 { return []; }
        let v = 0;
        for i in 0..len(p) {
            let d = hex_val(strings.slice(p, i, i + 1));
            if d < 0 { return []; }
            v = v * 16 + d;
        }
        push(out, v);
    }
    return out;
}
