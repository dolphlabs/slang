// A DNS client: A, AAAA, CNAME, MX, TXT, SRV, NS and PTR lookups over
// UDP, with TCP when an answer is truncated, /etc/resolv.conf and
// /etc/hosts, search domains, a TTL cache, and a deadline on every call.
//
//     import "dns";
//
//     let r = dns.system_resolver();
//     let ips = dns.lookup_ip(r, "api.example.com", deadline);  // ["192.0.2.7", "2001:db8::7"]
//     let mx = dns.lookup_mx(r, "example.com", deadline);       // by preference
//     let srv = dns.lookup_srv(r, "_imap._tcp.example.com", deadline);
//
// Queries go out on the reactor like any other socket, so a lookup parks
// its task and holds no thread (net.dial's getaddrinfo runs on a resolver
// thread instead). Answers are cached for their TTL, at most max_ttl; a
// name that does not exist, or has no records of the type asked, is
// cached for its zone's negative TTL (RFC 2308: the SOA's), and not at
// all when the server sent no SOA.
//
// Each query has a random id and goes out on a fresh socket, so its
// source port is random too. A reply is taken only from the server asked
// (the socket is connected to it), and only with the id and question
// that were sent; anything else is ignored while the query waits on.
//
// Errors: "no such host" when the name does not exist (NXDOMAIN, after
// every search domain), "timeout" when the deadline passed, and
// "dns: ..." for everything else. A name that exists but has no records
// of the type asked is ok([]).

import "builder";
import "crypto";
import "fs";
import "net";
import "strings";
import "time";

// Record types.
pub let A = 1;
pub let NS = 2;
pub let CNAME = 5;
pub let SOA = 6;
pub let PTR = 12;
pub let MX = 15;
pub let TXT = 16;
pub let AAAA = 28;
pub let SRV = 33;
let OPT = 41;

// Response codes.
pub let NOERROR = 0;
pub let FORMERR = 1;
pub let SERVFAIL = 2;
pub let NXDOMAIN = 3;
pub let NOTIMP = 4;
pub let REFUSED = 5;

// The EDNS0 payload size asked for: the 2020 DNS flag day's value, small
// enough that a reply is not fragmented on any ordinary path.
let UDP_SIZE = 1232;
let MAX_RECORDS = 4096;
// CNAME hops one lookup follows before giving up on a loop.
let MAX_CHAIN = 8;

// One resource record, decoded. `name` is lowercased with no final dot.
// `value` is the address (A, AAAA), the target name (CNAME, NS, PTR, MX,
// SRV, and SOA's primary server), or the text (TXT, its strings joined).
// `priority` is MX's preference or SRV's priority; `weight` and `port`
// are SRV's. A SOA's `ttl` is already its negative TTL: the lesser of the
// record's TTL and its MINIMUM field.
pub gc struct Record {
    name: str,
    rtype: int,
    ttl: int,
    value: str,
    priority: int,
    weight: int,
    port: int,
}

pub gc struct Question {
    name: str,
    qtype: int,
}

pub gc struct Message {
    id: int,
    response: bool,
    authoritative: bool,
    truncated: bool,
    recursion_desired: bool,
    recursion_available: bool,
    rcode: int,
    questions: [Question],
    answers: [Record],
    authority: [Record],
    additional: [Record],
}

// A name server: an IP literal and a port.
pub gc struct Server {
    host: str,
    port: int,
}

// What /etc/resolv.conf says. timeout is per try, in nanoseconds; a
// lookup makes up to attempts passes over servers.
pub gc struct Config {
    servers: [Server],
    search: [str],
    ndots: int,
    timeout: int,
    attempts: int,
    rotate: bool,
}

// /etc/hosts: addresses by lowercased name, in file order.
pub gc struct Hosts {
    by_name: map[str][str],
}

gc struct Entry {
    rcode: int,
    records: [Record],
    expires: int,
}

pub gc struct Resolver {
    cfg: Config,
    hosts: Hosts,
    mu: mutex,
    cache: map[str]Entry,
    // Entries kept at most; when full, expired ones go, and if none had
    // expired, all of them do (a burst of distinct names, not a steady
    // state, is what fills it).
    max_entries: int,
    // The longest any answer is cached, in seconds, whatever its TTL.
    max_ttl: int,
    next: int,
    sent: int,
}

// ---- names ---------------------------------------------------------------

// A name as it is compared and cached: lowercased, no final dot.
fn canonical(name: str) -> str {
    let n = strings.to_lower(name);
    if strings.has_suffix(n, ".") {
        n = strings.slice(n, 0, len(n) - 1);
    }
    return n;
}

fn label_byte_ok(c: int) -> bool {
    return c > 0x20 && c < 0x7f && c != 0x2e;
}

fn encode_name(b: builder.Bytes, name: str) -> result[int, str] {
    let n = canonical(name);
    if len(n) == 0 {
        b.write_byte(0);
        return ok(1);
    }
    if len(n) > 253 {
        return err("dns: name longer than 253 bytes: " + name);
    }
    for label in strings.split(n, ".") {
        let lb = to_bytes(label);
        if len(lb) == 0 {
            return err("dns: empty label in " + name);
        }
        if len(lb) > 63 {
            return err("dns: label longer than 63 bytes in " + name);
        }
        for c in lb {
            if !label_byte_ok(c as int) {
                return err("dns: name holds a byte no label may: " + name);
            }
        }
        b.write_byte(len(lb));
        b.write(lb);
    }
    b.write_byte(0);
    return ok(len(n) + 2);
}

struct NameAt {
    name: str,
    next: int,
    fail: str,
}

fn name_fail(why: str) -> NameAt {
    return NameAt { name: "", next: 0, fail: why };
}

// The name at `at`, following compression pointers. A pointer must point
// before itself, so every jump goes back and a loop cannot form.
fn read_name(b: bytes, at: int) -> NameAt {
    let parts: [str] = [];
    let pos = at;
    let next = -1;
    let total = 0;
    while true {
        if pos >= len(b) {
            return name_fail("dns: a name runs past the message");
        }
        let l = b[pos] as int;
        if l == 0 {
            if next < 0 {
                next = pos + 1;
            }
            break;
        }
        if (l & 0xC0) == 0xC0 {
            if pos + 1 >= len(b) {
                return name_fail("dns: a name runs past the message");
            }
            let ptr = ((l & 0x3F) << 8) | (b[pos + 1] as int);
            if next < 0 {
                next = pos + 2;
            }
            if ptr >= pos {
                return name_fail("dns: a compression pointer does not point back");
            }
            pos = ptr;
            continue;
        }
        if (l & 0xC0) != 0 {
            return name_fail("dns: unknown label type");
        }
        if pos + 1 + l > len(b) {
            return name_fail("dns: a name runs past the message");
        }
        total = total + l + 1;
        if total > 254 {
            return name_fail("dns: a name longer than 255 bytes");
        }
        let i = pos + 1;
        while i < pos + 1 + l {
            if !label_byte_ok(b[i] as int) {
                return name_fail("dns: a label holds a byte no name may");
            }
            i = i + 1;
        }
        push(parts, strings.from_bytes_lower(b, pos + 1, pos + 1 + l));
        pos = pos + 1 + l;
    }
    return NameAt { name: strings.join(parts, "."), next: next, fail: "" };
}

// ---- addresses -----------------------------------------------------------

fn hex_val(c: int) -> int {
    if c >= 0x30 && c <= 0x39 { return c - 0x30; }
    if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10; }
    if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10; }
    return -1;
}

fn parse_v4(s: str) -> opt[bytes] {
    let parts = strings.split(s, ".");
    if len(parts) != 4 {
        return none;
    }
    let out = builder.new_bytes();
    for p in parts {
        let pb = to_bytes(p);
        if len(pb) == 0 || len(pb) > 3 {
            return none;
        }
        // No leading zeros: 010 is octal to some parsers and decimal to
        // others, so it is neither here.
        if len(pb) > 1 && pb[0] == 0x30 {
            return none;
        }
        let v = 0;
        for c in pb {
            let d = (c as int) - 0x30;
            if d < 0 || d > 9 {
                return none;
            }
            v = v * 10 + d;
        }
        if v > 255 {
            return none;
        }
        out.write_byte(v);
    }
    return some(out.finish());
}

fn parse_groups(s: str, into: [int]) -> bool {
    if len(s) == 0 {
        return true;
    }
    for g in strings.split(s, ":") {
        let gb = to_bytes(g);
        if len(gb) == 0 || len(gb) > 4 {
            return false;
        }
        let v = 0;
        for c in gb {
            let d = hex_val(c as int);
            if d < 0 {
                return false;
            }
            v = v * 16 + d;
        }
        push(into, v);
    }
    return true;
}

fn parse_v6(text: str) -> opt[bytes] {
    let s = text;
    // A dotted IPv4 tail ("::ffff:192.0.2.1") is the last two groups.
    let tail: [int] = [];
    let last_colon = strings.rfind(s, ":");
    if last_colon >= 0 && strings.contains(strings.slice(s, last_colon + 1, len(s)), ".") {
        let v4 = parse_v4(strings.slice(s, last_colon + 1, len(s)));
        guard let four = v4 else {
            return none;
        }
        push(tail, ((four[0] as int) << 8) | (four[1] as int));
        push(tail, ((four[2] as int) << 8) | (four[3] as int));
        s = strings.slice(s, 0, last_colon + 1);
        if strings.has_suffix(s, "::") {
            // "::1.2.3.4": the gap ends at the tail
        } else {
            s = strings.slice(s, 0, len(s) - 1);
        }
    }
    let head: [int] = [];
    let rest: [int] = [];
    let gap = strings.find(s, "::");
    if gap >= 0 {
        if strings.find(strings.slice(s, gap + 2, len(s)), "::") >= 0 {
            return none;
        }
        if !parse_groups(strings.slice(s, 0, gap), head) {
            return none;
        }
        if !parse_groups(strings.slice(s, gap + 2, len(s)), rest) {
            return none;
        }
    } else {
        if !parse_groups(s, head) {
            return none;
        }
    }
    for t in tail {
        push(rest, t);
    }
    let have = len(head) + len(rest);
    if gap < 0 && have != 8 {
        return none;
    }
    if gap >= 0 && have > 7 {
        return none;
    }
    let groups: [int] = [];
    for h in head {
        push(groups, h);
    }
    let fill = 8 - have;
    let i = 0;
    while i < fill {
        push(groups, 0);
        i = i + 1;
    }
    for r in rest {
        push(groups, r);
    }
    let out = builder.new_bytes();
    for g in groups {
        out.write_byte(g >> 8);
        out.write_byte(g & 255);
    }
    return some(out.finish());
}

// An IP address in text: 4 bytes for IPv4, 16 for IPv6.
pub fn parse_ip(s: str) -> result[bytes, str] {
    if strings.contains(s, ":") {
        if let b = parse_v6(s) {
            return ok(b);
        }
        return err("dns: not an IPv6 address: " + s);
    }
    if let b = parse_v4(s) {
        return ok(b);
    }
    return err("dns: not an IP address: " + s);
}

let HEX = "0123456789abcdef";

fn hex_group(v: int) -> str {
    let out = "";
    let started = false;
    let shift = 12;
    while shift >= 0 {
        let d = (v >> shift) & 15;
        if d != 0 || started || shift == 0 {
            out = out + strings.slice(HEX, d, d + 1);
            started = true;
        }
        shift = shift - 4;
    }
    return out;
}

fn format_v4(b: bytes, at: int) -> str {
    return to_str(b[at] as int) + "." + to_str(b[at + 1] as int) + "." +
           to_str(b[at + 2] as int) + "." + to_str(b[at + 3] as int);
}

// RFC 5952: lowercase, no leading zeros, the longest run of two or more
// zero groups (the first, on a tie) written as "::".
fn format_v6(b: bytes, at: int) -> str {
    let g: [int] = [];
    let i = 0;
    while i < 8 {
        push(g, ((b[at + 2 * i] as int) << 8) | (b[at + 2 * i + 1] as int));
        i = i + 1;
    }
    let best = -1;
    let best_len = 1;
    let run = -1;
    let j = 0;
    while j <= 8 {
        if j < 8 && g[j] == 0 {
            if run < 0 {
                run = j;
            }
        } else {
            if run >= 0 && j - run > best_len {
                best = run;
                best_len = j - run;
            }
            run = -1;
        }
        j = j + 1;
    }
    let out = builder.new_str();
    let k = 0;
    while k < 8 {
        if k == best {
            out.write("::");
            k = k + best_len;
            continue;
        }
        if k > 0 && k != best + best_len {
            out.write(":");
        }
        out.write(hex_group(g[k]));
        k = k + 1;
    }
    return out.finish();
}

// An address's canonical text: dotted IPv4, or RFC 5952 IPv6.
pub fn format_ip(b: bytes) -> str {
    if len(b) == 4 {
        return format_v4(b, 0);
    }
    if len(b) == 16 {
        return format_v6(b, 0);
    }
    return "";
}

// The PTR name for an address: "4.3.2.1.in-addr.arpa" or the IPv6
// nibbles under ip6.arpa.
pub fn reverse_name(ip: str) -> result[str, str] {
    let pr = parse_ip(ip);
    guard let b = pr else let e = err_of(pr) {
        return err(e);
    }
    let parts: [str] = [];
    if len(b) == 4 {
        let i = 3;
        while i >= 0 {
            push(parts, to_str(b[i] as int));
            i = i - 1;
        }
        push(parts, "in-addr.arpa");
        return ok(strings.join(parts, "."));
    }
    let i = 15;
    while i >= 0 {
        let v = b[i] as int;
        push(parts, strings.slice(HEX, v & 15, (v & 15) + 1));
        push(parts, strings.slice(HEX, v >> 4, (v >> 4) + 1));
        i = i - 1;
    }
    push(parts, "ip6.arpa");
    return ok(strings.join(parts, "."));
}

// ---- messages ------------------------------------------------------------

fn put16(b: builder.Bytes, v: int) {
    b.write_byte((v >> 8) & 255);
    b.write_byte(v & 255);
}

fn put32(b: builder.Bytes, v: int) {
    put16(b, (v >> 16) & 65535);
    put16(b, v & 65535);
}

fn get16(b: bytes, at: int) -> int {
    return ((b[at] as int) << 8) | (b[at + 1] as int);
}

fn get32(b: bytes, at: int) -> int {
    return (get16(b, at) << 16) | get16(b, at + 2);
}

// A query for `name`, recursion desired, with an EDNS0 OPT record asking
// for answers up to 1232 bytes over UDP.
pub fn encode_query(id: int, name: str, qtype: int) -> result[bytes, str] {
    let b = builder.new_bytes();
    put16(b, id & 65535);
    put16(b, 0x0100);
    put16(b, 1);
    put16(b, 0);
    put16(b, 0);
    put16(b, 1);
    let nr = encode_name(b, name);
    guard let _n = nr else let e = err_of(nr) {
        return err(e);
    }
    put16(b, qtype);
    put16(b, 1);
    b.write_byte(0);
    put16(b, OPT);
    put16(b, UDP_SIZE);
    put32(b, 0);
    put16(b, 0);
    return ok(b.finish());
}

fn encode_rdata(b: builder.Bytes, r: Record) -> result[int, str] {
    let body = builder.new_bytes();
    if r.rtype == A || r.rtype == AAAA {
        let pr = parse_ip(r.value);
        guard let ip = pr else let e = err_of(pr) {
            return err(e);
        }
        if (r.rtype == A && len(ip) != 4) || (r.rtype == AAAA && len(ip) != 16) {
            return err("dns: " + r.value + " is the wrong family for its record");
        }
        body.write(ip);
    } else if r.rtype == CNAME || r.rtype == NS || r.rtype == PTR {
        let nr = encode_name(body, r.value);
        guard let _n = nr else let e = err_of(nr) { return err(e); }
    } else if r.rtype == MX {
        put16(body, r.priority);
        let nr = encode_name(body, r.value);
        guard let _n = nr else let e = err_of(nr) { return err(e); }
    } else if r.rtype == SRV {
        put16(body, r.priority);
        put16(body, r.weight);
        put16(body, r.port);
        let nr = encode_name(body, r.value);
        guard let _n = nr else let e = err_of(nr) { return err(e); }
    } else if r.rtype == TXT {
        let tb = to_bytes(r.value);
        let at = 0;
        // One empty string for empty text; otherwise 255-byte pieces.
        if len(tb) == 0 {
            body.write_byte(0);
        }
        while at < len(tb) {
            let end = at + 255;
            if end > len(tb) {
                end = len(tb);
            }
            body.write_byte(end - at);
            body.write(tb[at..end]);
            at = end;
        }
    } else if r.rtype == SOA {
        // Only what this package reads back: the primary server, and the
        // negative TTL as MINIMUM.
        let nr = encode_name(body, r.value);
        guard let _n = nr else let e = err_of(nr) { return err(e); }
        body.write_byte(0);
        put32(body, 1);
        put32(body, 3600);
        put32(body, 600);
        put32(body, 86400);
        put32(body, r.ttl);
    } else {
        return err("dns: cannot encode record type " + to_str(r.rtype));
    }
    let rd = body.finish();
    if len(rd) > 65535 {
        return err("dns: record data longer than 65535 bytes");
    }
    put16(b, len(rd));
    b.write(rd);
    return ok(len(rd));
}

fn encode_record(b: builder.Bytes, r: Record) -> result[int, str] {
    let nr = encode_name(b, r.name);
    guard let _n = nr else let e = err_of(nr) {
        return err(e);
    }
    put16(b, r.rtype);
    put16(b, 1);
    put32(b, r.ttl);
    return encode_rdata(b, r);
}

// A whole message, uncompressed: for a server, or a test's fake one.
pub fn encode(m: Message) -> result[bytes, str] {
    let b = builder.new_bytes();
    put16(b, m.id & 65535);
    let flags = (m.rcode & 15);
    if m.response { flags = flags | 0x8000; }
    if m.authoritative { flags = flags | 0x0400; }
    if m.truncated { flags = flags | 0x0200; }
    if m.recursion_desired { flags = flags | 0x0100; }
    if m.recursion_available { flags = flags | 0x0080; }
    put16(b, flags);
    put16(b, len(m.questions));
    put16(b, len(m.answers));
    put16(b, len(m.authority));
    put16(b, len(m.additional));
    for q in m.questions {
        let nr = encode_name(b, q.name);
        guard let _n = nr else let e = err_of(nr) {
            return err(e);
        }
        put16(b, q.qtype);
        put16(b, 1);
    }
    for section in [m.answers, m.authority, m.additional] {
        for r in section {
            let rr = encode_record(b, r);
            guard let _r = rr else let e = err_of(rr) {
                return err(e);
            }
        }
    }
    return ok(b.finish());
}

struct RecordAt {
    rec: Record,
    keep: bool,
    next: int,
    fail: str,
}

fn record_fail(why: str) -> RecordAt {
    return RecordAt { rec: Record { name: "", rtype: 0, ttl: 0, value: "", priority: 0,
                                    weight: 0, port: 0 },
                      keep: false, next: 0, fail: why };
}

// A name inside record data: it must end inside the record.
fn rdata_name(b: bytes, at: int, end: int) -> NameAt {
    let na = read_name(b, at);
    if len(na.fail) == 0 && na.next > end {
        return name_fail("dns: a name runs past its record");
    }
    return na;
}

fn read_record(b: bytes, at: int) -> RecordAt {
    let na = read_name(b, at);
    if len(na.fail) > 0 {
        return record_fail(na.fail);
    }
    let p = na.next;
    if p + 10 > len(b) {
        return record_fail("dns: a record runs past the message");
    }
    let rtype = get16(b, p);
    let class = get16(b, p + 2);
    let ttl = get32(b, p + 4);
    // RFC 2181: a TTL with the top bit set is zero.
    if ttl >= 2147483648 {
        ttl = 0;
    }
    let rdlen = get16(b, p + 8);
    let d = p + 10;
    let end = d + rdlen;
    if end > len(b) {
        return record_fail("dns: a record runs past the message");
    }
    let r = Record { name: na.name, rtype: rtype, ttl: ttl, value: "", priority: 0,
                     weight: 0, port: 0 };
    let keep = class == 1;
    if rtype == A && keep {
        if rdlen != 4 {
            return record_fail("dns: an A record is not 4 bytes");
        }
        r.value = format_v4(b, d);
    } else if rtype == AAAA && keep {
        if rdlen != 16 {
            return record_fail("dns: an AAAA record is not 16 bytes");
        }
        r.value = format_v6(b, d);
    } else if (rtype == CNAME || rtype == NS || rtype == PTR) && keep {
        let tn = rdata_name(b, d, end);
        if len(tn.fail) > 0 {
            return record_fail(tn.fail);
        }
        r.value = tn.name;
    } else if rtype == MX && keep {
        if rdlen < 3 {
            return record_fail("dns: an MX record is too short");
        }
        r.priority = get16(b, d);
        let tn = rdata_name(b, d + 2, end);
        if len(tn.fail) > 0 {
            return record_fail(tn.fail);
        }
        r.value = tn.name;
    } else if rtype == SRV && keep {
        if rdlen < 7 {
            return record_fail("dns: an SRV record is too short");
        }
        r.priority = get16(b, d);
        r.weight = get16(b, d + 2);
        r.port = get16(b, d + 4);
        let tn = rdata_name(b, d + 6, end);
        if len(tn.fail) > 0 {
            return record_fail(tn.fail);
        }
        r.value = tn.name;
    } else if rtype == TXT && keep {
        let text = builder.new_bytes();
        let q = d;
        while q < end {
            let l = b[q] as int;
            if q + 1 + l > end {
                return record_fail("dns: a TXT string runs past its record");
            }
            let i = q + 1;
            while i < q + 1 + l {
                if b[i] == 0 {
                    return record_fail("dns: a TXT record holds a NUL byte");
                }
                i = i + 1;
            }
            text.write(b[q + 1..q + 1 + l]);
            q = q + 1 + l;
        }
        r.value = to_str(text.finish());
    } else if rtype == SOA && keep {
        let mn = rdata_name(b, d, end);
        if len(mn.fail) > 0 {
            return record_fail(mn.fail);
        }
        let rn = rdata_name(b, mn.next, end);
        if len(rn.fail) > 0 {
            return record_fail(rn.fail);
        }
        if rn.next + 20 > end {
            return record_fail("dns: a SOA record is too short");
        }
        let minimum = get32(b, rn.next + 16);
        if minimum < ttl {
            r.ttl = minimum;
        }
        r.value = mn.name;
    } else {
        // OPT, other classes and types this package does not read: kept
        // in step, never returned.
        keep = false;
    }
    return RecordAt { rec: r, keep: keep, next: end, fail: "" };
}

// A message from the wire. Records this package does not read (OPT,
// other classes, other types) are skipped.
pub fn decode(b: bytes) -> result[Message, str] {
    if len(b) < 12 {
        return err("dns: a message shorter than its header");
    }
    let flags = get16(b, 2);
    let qd = get16(b, 4);
    let counts = [get16(b, 6), get16(b, 8), get16(b, 10)];
    if qd + counts[0] + counts[1] + counts[2] > MAX_RECORDS {
        return err("dns: a message with too many records");
    }
    let m = Message {
        id: get16(b, 0),
        response: (flags & 0x8000) != 0,
        authoritative: (flags & 0x0400) != 0,
        truncated: (flags & 0x0200) != 0,
        recursion_desired: (flags & 0x0100) != 0,
        recursion_available: (flags & 0x0080) != 0,
        rcode: flags & 15,
        questions: [], answers: [], authority: [], additional: []
    };
    let at = 12;
    let i = 0;
    while i < qd {
        let na = read_name(b, at);
        if len(na.fail) > 0 {
            return err(na.fail);
        }
        if na.next + 4 > len(b) {
            return err("dns: a question runs past the message");
        }
        push(m.questions, Question { name: na.name, qtype: get16(b, na.next) });
        at = na.next + 4;
        i = i + 1;
    }
    let s = 0;
    while s < 3 {
        let k = 0;
        while k < counts[s] {
            let ra = read_record(b, at);
            if len(ra.fail) > 0 {
                return err(ra.fail);
            }
            if ra.keep {
                if s == 0 {
                    push(m.answers, ra.rec);
                } else if s == 1 {
                    push(m.authority, ra.rec);
                } else {
                    push(m.additional, ra.rec);
                }
            }
            at = ra.next;
            k = k + 1;
        }
        s = s + 1;
    }
    return ok(m);
}

// ---- one exchange --------------------------------------------------------

fn new_id() -> result[int, str] {
    let rr = crypto.rand(2);
    guard let rb = rr else let e = err_of(rr) {
        return err("dns: no random id: " + e);
    }
    return ok(get16(rb, 0));
}

// Whether `m` answers the query that was sent.
fn answers(m: Message, id: int, name: str, qtype: int) -> bool {
    if !m.response || m.id != id || len(m.questions) != 1 {
        return false;
    }
    return m.questions[0].name == name && m.questions[0].qtype == qtype;
}

fn exchange_tcp(s: Server, q: bytes, id: int, name: str, qtype: int,
                deadline: until) -> result[Message, str] {
    let dr = net.dial_until(s.host, s.port, deadline);
    guard let fd = dr else let e = err_of(dr) {
        return err(e);
    }
    let framed = builder.new_bytes();
    put16(framed, len(q));
    framed.write(q);
    let sr = net.send_until(fd as int, framed.finish(), deadline);
    guard let _s = sr else let e = err_of(sr) {
        net.close(fd as int);
        return err(e);
    }
    let buf = b"";
    let want = -1;
    while want < 0 || len(buf) < want + 2 {
        if want < 0 && len(buf) >= 2 {
            want = get16(buf, 0);
            continue;
        }
        let rr = net.recv_until(fd as int, 65537, deadline);
        guard let more = rr else let e = err_of(rr) {
            net.close(fd as int);
            return err(e);
        }
        if len(more) == 0 {
            net.close(fd as int);
            return err("dns: the server closed the connection mid-answer");
        }
        buf = buf + more;
    }
    net.close(fd as int);
    let mr = decode(buf[2..want + 2]);
    guard let m = mr else let e = err_of(mr) {
        return err(e);
    }
    if !answers(m, id, name, qtype) {
        return err("dns: the server answered a different question");
    }
    return ok(m);
}

// One query to one server: over UDP, then over TCP when the answer came
// back truncated. Replies that are malformed, or answer some other query,
// are ignored and the wait goes on until `deadline`.
pub fn exchange(s: Server, name: str, qtype: int, deadline: until) -> result[Message, str] {
    let qname = canonical(name);
    let ir = new_id();
    guard let id = ir else let e = err_of(ir) {
        return err(e);
    }
    let qr = encode_query(id, qname, qtype);
    guard let q = qr else let e = err_of(qr) {
        return err(e);
    }
    let dr = net.udp_dial(s.host, s.port, deadline);
    guard let fd = dr else let e = err_of(dr) {
        return err(e);
    }
    let sr = net.send_until(fd as int, q, deadline);
    guard let _s = sr else let e = err_of(sr) {
        net.close(fd as int);
        return err(e);
    }
    while true {
        let rr = net.recv_until(fd as int, 65535, deadline);
        guard let pkt = rr else let e = err_of(rr) {
            net.close(fd as int);
            return err(e);
        }
        let mr = decode(pkt);
        guard let m = mr else {
            continue;
        }
        if !answers(m, id, qname, qtype) {
            continue;
        }
        net.close(fd as int);
        if m.truncated {
            return exchange_tcp(s, q, id, qname, qtype, deadline);
        }
        return ok(m);
    }
    net.close(fd as int);
    return err("timeout");
}

// ---- configuration -------------------------------------------------------

fn fields(line: str) -> [str] {
    let out: [str] = [];
    for f in strings.split(strings.replace(line, "\t", " "), " ") {
        if len(f) > 0 {
            push(out, f);
        }
    }
    return out;
}

fn uncomment(line: str, marks: [str]) -> str {
    let cut = len(line);
    for m in marks {
        let at = strings.find(line, m);
        if at >= 0 && at < cut {
            cut = at;
        }
    }
    return strings.slice(line, 0, cut);
}

fn local_servers() -> [Server] {
    return [Server { host: "127.0.0.1", port: 53 }, Server { host: "::1", port: 53 }];
}

// What a machine with no resolv.conf gets, as glibc and Go do: the local
// host on port 53, ndots 1, 5s per try, 2 attempts.
pub fn default_config() -> Config {
    return Config { servers: local_servers(), search: [], ndots: 1,
                    timeout: 5000000000, attempts: 2, rotate: false };
}

fn option_int(o: str, prefix: str, lo: int, hi: int, fallback: int) -> int {
    let v = to_int(strings.slice(o, len(prefix), len(o))) ?? fallback;
    if v < lo { return lo; }
    if v > hi { return hi; }
    return v;
}

// /etc/resolv.conf's text: nameserver, search, domain, and the options
// ndots, timeout, attempts and rotate (caps as glibc's: ndots 15,
// timeout 30s, attempts 5). A nameserver that is not an IP address is
// skipped; with none left, the local host is used.
pub fn parse_resolv_conf(text: str) -> Config {
    let cfg = default_config();
    let servers: [Server] = [];
    for raw in strings.split(text, "\n") {
        let f = fields(uncomment(raw, ["#", ";"]));
        if len(f) < 2 {
            continue;
        }
        if f[0] == "nameserver" {
            let host = f[1];
            let zone = strings.find(host, "%");
            let bare = host;
            if zone >= 0 {
                bare = strings.slice(host, 0, zone);
            }
            if let _ip = parse_ip(bare) {
                push(servers, Server { host: host, port: 53 });
            }
        } else if f[0] == "search" {
            let s: [str] = [];
            for d in f[1..] {
                push(s, canonical(d));
            }
            cfg.search = s;
        } else if f[0] == "domain" {
            cfg.search = [canonical(f[1])];
        } else if f[0] == "options" {
            for o in f[1..] {
                if strings.has_prefix(o, "ndots:") {
                    cfg.ndots = option_int(o, "ndots:", 0, 15, 1);
                } else if strings.has_prefix(o, "timeout:") {
                    cfg.timeout = option_int(o, "timeout:", 1, 30, 5) * 1000000000;
                } else if strings.has_prefix(o, "attempts:") {
                    cfg.attempts = option_int(o, "attempts:", 1, 5, 2);
                } else if o == "rotate" {
                    cfg.rotate = true;
                }
            }
        }
    }
    if len(servers) > 0 {
        cfg.servers = servers;
    }
    return cfg;
}

fn read_text(path: str) -> result[str, str] {
    let fr = fs.open(path);
    guard let fd = fr else let e = err_of(fr) {
        return err(e);
    }
    let parts: [bytes] = [];
    let total = 0;
    while true {
        let rr = fs.read(fd as int, 65536);
        guard let b = rr else let e = err_of(rr) {
            fs.close(fd as int);
            return err(e);
        }
        if len(b) == 0 {
            break;
        }
        total = total + len(b);
        if total > 4194304 {
            fs.close(fd as int);
            return err("dns: " + path + " is larger than 4MB");
        }
        push(parts, b);
    }
    fs.close(fd as int);
    return ok(to_str(strings.join_bytes(parts, b"")));
}

// /etc/resolv.conf, or default_config() when it cannot be read.
pub fn system_config() -> Config {
    let tr = read_text("/etc/resolv.conf");
    guard let text = tr else {
        return default_config();
    }
    return parse_resolv_conf(text);
}

pub fn no_hosts() -> Hosts {
    let m: map[str][str] = {};
    return Hosts { by_name: m };
}

// A hosts file's text: an address, then its names. Lines whose address
// does not parse are skipped.
pub fn parse_hosts(text: str) -> Hosts {
    let h = no_hosts();
    for raw in strings.split(text, "\n") {
        let f = fields(uncomment(raw, ["#"]));
        if len(f) < 2 {
            continue;
        }
        let pr = parse_ip(f[0]);
        guard let ip = pr else {
            continue;
        }
        let addr = format_ip(ip);
        for n in f[1..] {
            let name = canonical(n);
            if !has(h.by_name, name) {
                let none_yet: [str] = [];
                h.by_name[name] = none_yet;
            }
            push(h.by_name[name], addr);
        }
    }
    return h;
}

// /etc/hosts, or no hosts when it cannot be read.
pub fn system_hosts() -> Hosts {
    let tr = read_text("/etc/hosts");
    guard let text = tr else {
        return no_hosts();
    }
    return parse_hosts(text);
}

// ---- the resolver --------------------------------------------------------

pub fn new_resolver(cfg: Config, hosts: Hosts) -> Resolver {
    let c: map[str]Entry = {};
    return Resolver { cfg: cfg, hosts: hosts, mu: make_mutex(), cache: c,
                      max_entries: 10000, max_ttl: 3600, next: 0, sent: 0 };
}

// A resolver over /etc/resolv.conf and /etc/hosts, read once, now.
pub fn system_resolver() -> Resolver {
    return new_resolver(system_config(), system_hosts());
}

// How many queries this resolver has sent: answers from the cache or
// hosts send none.
pub fn queries_sent(r: Resolver) -> int {
    mutex_lock(r.mu);
    let n = r.sent;
    mutex_unlock(r.mu);
    return n;
}

pub fn cache_len(r: Resolver) -> int {
    mutex_lock(r.mu);
    let n = len(r.cache);
    mutex_unlock(r.mu);
    return n;
}

pub fn cache_clear(r: Resolver) {
    mutex_lock(r.mu);
    let c: map[str]Entry = {};
    r.cache = c;
    mutex_unlock(r.mu);
}

fn now_ns() -> int {
    return time.mono() as int;
}

fn cache_get(r: Resolver, key: str) -> opt[Entry] {
    mutex_lock(r.mu);
    if !has(r.cache, key) {
        mutex_unlock(r.mu);
        return none;
    }
    let e = r.cache[key];
    if e.expires <= now_ns() {
        del(r.cache, key);
        mutex_unlock(r.mu);
        return none;
    }
    mutex_unlock(r.mu);
    return some(e);
}

fn cache_put(r: Resolver, key: str, e: Entry) {
    mutex_lock(r.mu);
    if len(r.cache) >= r.max_entries && !has(r.cache, key) {
        let now = now_ns();
        let live: map[str]Entry = {};
        for k, v in r.cache {
            if v.expires > now {
                live[k] = v;
            }
        }
        if len(live) >= r.max_entries {
            let fresh: map[str]Entry = {};
            live = fresh;
        }
        r.cache = live;
    }
    r.cache[key] = e;
    mutex_unlock(r.mu);
}

// The entry an answer is cached as: the chain of records it gave for
// the name (CNAMEs and records of the type asked), for the least TTL
// among them, or for the SOA's negative TTL when there are none.
fn entry_of(r: Resolver, m: Message, qtype: int) -> Entry {
    let kept: [Record] = [];
    let ttl = -1;
    for a in m.answers {
        if a.rtype == qtype || a.rtype == CNAME {
            push(kept, a);
            if ttl < 0 || a.ttl < ttl {
                ttl = a.ttl;
            }
        }
    }
    if len(kept) == 0 || m.rcode == NXDOMAIN {
        ttl = 0;
        for s in m.authority {
            if s.rtype == SOA {
                ttl = s.ttl;
            }
        }
    }
    if ttl > r.max_ttl {
        ttl = r.max_ttl;
    }
    if ttl < 0 {
        ttl = 0;
    }
    return Entry { rcode: m.rcode, records: kept, expires: now_ns() + ttl * 1000000000 };
}

fn count_sent(r: Resolver) -> int {
    mutex_lock(r.mu);
    r.sent = r.sent + 1;
    let start = 0;
    if r.cfg.rotate {
        start = r.next;
        r.next = r.next + 1;
    }
    mutex_unlock(r.mu);
    return start;
}

// One name, one type, from the cache or the servers: NOERROR and
// NXDOMAIN are answers; SERVFAIL, REFUSED and the rest move on to the
// next server.
fn resolve(r: Resolver, name: str, qtype: int, deadline: until) -> result[Entry, str] {
    let key = to_str(qtype) + " " + name;
    if let hit = cache_get(r, key) {
        return ok(hit);
    }
    let n = len(r.cfg.servers);
    if n == 0 {
        return err("dns: no name servers");
    }
    let last = "timeout";
    let attempt = 0;
    while attempt < r.cfg.attempts {
        let i = 0;
        while i < n {
            if until_hit(deadline) {
                return err("timeout");
            }
            let start = count_sent(r);
            let s = r.cfg.servers[(start + i) % n];
            let try_by = until_min(deadline, until_of(now_ns() + r.cfg.timeout));
            let mr = exchange(s, name, qtype, try_by);
            guard let m = mr else let e = err_of(mr) {
                last = e;
                i = i + 1;
                continue;
            }
            if m.rcode == NOERROR || m.rcode == NXDOMAIN {
                let e = entry_of(r, m, qtype);
                if e.expires > now_ns() {
                    cache_put(r, key, e);
                }
                return ok(e);
            }
            last = "dns: " + s.host + " answered with rcode " + to_str(m.rcode);
            i = i + 1;
        }
        attempt = attempt + 1;
    }
    return err(last);
}

// The records of `qtype` for exactly `name`, following CNAMEs inside an
// answer and, when a chain leaves it, with a new query for its target.
// none for NXDOMAIN; some([]) when the name has no such records.
fn follow(r: Resolver, name: str, qtype: int, deadline: until) -> result[opt[[Record]], str] {
    let target = name;
    let hops = 0;
    while hops <= MAX_CHAIN {
        let er = resolve(r, target, qtype, deadline);
        guard let e = er else let x = err_of(er) {
            return err(x);
        }
        if e.rcode == NXDOMAIN && target == name {
            return ok(none);
        }
        if qtype == CNAME {
            let direct: [Record] = [];
            for rec in e.records {
                if rec.rtype == CNAME && rec.name == target {
                    push(direct, rec);
                }
            }
            return ok(some(direct));
        }
        let cur = target;
        let steps = 0;
        let found: [Record] = [];
        while steps <= MAX_CHAIN {
            for rec in e.records {
                if rec.rtype == qtype && rec.name == cur {
                    push(found, rec);
                }
            }
            if len(found) > 0 {
                return ok(some(found));
            }
            let moved = false;
            for rec in e.records {
                if !moved && rec.rtype == CNAME && rec.name == cur {
                    cur = rec.value;
                    moved = true;
                }
            }
            if !moved {
                break;
            }
            steps = steps + 1;
        }
        if cur == target {
            let empty: [Record] = [];
            return ok(some(empty));
        }
        target = cur;
        hops = hops + 1;
    }
    return err("dns: a CNAME chain longer than " + to_str(MAX_CHAIN) + " for " + name);
}

// The names a lookup tries, in order: a name with a final dot as it is;
// one with at least ndots dots first as it is, then with each search
// domain; one with fewer, the other way round.
fn candidates(r: Resolver, name: str) -> [str] {
    let base = canonical(name);
    let out: [str] = [];
    if strings.has_suffix(name, ".") {
        push(out, base);
        return out;
    }
    let dots = strings.count(base, ".");
    if dots >= r.cfg.ndots {
        push(out, base);
    }
    for s in r.cfg.search {
        if len(s) > 0 {
            push(out, base + "." + s);
        }
    }
    if dots < r.cfg.ndots {
        push(out, base);
    }
    return out;
}

// The records of `qtype` for `name`, after search domains and CNAMEs.
// err("no such host") when no candidate name exists; ok([]) when one
// exists without records of this type.
pub fn lookup(r: Resolver, name: str, qtype: int, deadline: until) -> result[[Record], str] {
    let check = builder.new_bytes();
    let vr = encode_name(check, name);
    guard let _v = vr else let e = err_of(vr) {
        return err(e);
    }
    let exists = false;
    for c in candidates(r, name) {
        let fr = follow(r, c, qtype, deadline);
        guard let found = fr else let e = err_of(fr) {
            return err(e);
        }
        if let recs = found {
            if len(recs) > 0 {
                return ok(recs);
            }
            exists = true;
        }
    }
    if exists {
        let empty: [Record] = [];
        return ok(empty);
    }
    return err("no such host");
}

gc struct IpAnswer {
    qtype: int,
    ips: [str],
    fail: str,
    missing: bool,
}

fn ip_task(r: Resolver, name: str, qtype: int, deadline: until, out: chan[IpAnswer]) {
    let lr = lookup(r, name, qtype, deadline);
    let ips: [str] = [];
    guard let recs = lr else let e = err_of(lr) {
        chan_send(out, IpAnswer { qtype: qtype, ips: ips, fail: e, missing: e == "no such host" });
        return;
    }
    for rec in recs {
        push(ips, rec.value);
    }
    chan_send(out, IpAnswer { qtype: qtype, ips: ips, fail: "", missing: false });
}

// The addresses of `host`: IPv4 first, then IPv6. An IP literal is
// itself; then /etc/hosts; "localhost" and names under it are the
// loopback addresses (RFC 6761); anything else asks for A and AAAA at
// once. One family failing while the other answers is not an error.
pub fn lookup_ip(r: Resolver, host: str, deadline: until) -> result[[str], str] {
    let bare = host;
    if strings.has_prefix(bare, "[") && strings.has_suffix(bare, "]") {
        bare = strings.slice(bare, 1, len(bare) - 1);
    }
    if let ip = parse_ip(bare) {
        return ok([format_ip(ip)]);
    }
    let name = canonical(bare);
    if has(r.hosts.by_name, name) {
        // A copy: the caller may change what it gets.
        let listed: [str] = [];
        for a in r.hosts.by_name[name] {
            push(listed, a);
        }
        return ok(listed);
    }
    if name == "localhost" || strings.has_suffix(name, ".localhost") {
        return ok(["127.0.0.1", "::1"]);
    }
    let ch: chan[IpAnswer] = make_chan(2);
    spawn ip_task(r, bare, A, deadline, ch);
    spawn ip_task(r, bare, AAAA, deadline, ch);
    let lost: [str] = [];
    let gone = IpAnswer { qtype: 0, ips: lost, fail: "dns: a lookup task ended early", missing: false };
    let first = chan_recv(ch) ?? gone;
    let second = chan_recv(ch) ?? gone;
    let v4 = first;
    let v6 = second;
    if first.qtype == AAAA {
        v4 = second;
        v6 = first;
    }
    let out: [str] = [];
    for a in v4.ips {
        push(out, a);
    }
    for a in v6.ips {
        push(out, a);
    }
    if len(out) > 0 {
        return ok(out);
    }
    if len(v4.fail) > 0 && !v4.missing {
        return err(v4.fail);
    }
    if len(v6.fail) > 0 && !v6.missing {
        return err(v6.fail);
    }
    return err("no such host");
}

fn values(rr: result[[Record], str]) -> result[[str], str] {
    guard let recs = rr else let e = err_of(rr) {
        return err(e);
    }
    let out: [str] = [];
    for rec in recs {
        push(out, rec.value);
    }
    return ok(out);
}

// Lowest first by `priority`, then highest `weight` first; stable.
fn by_priority(recs: [Record]) -> [Record] {
    let out: [Record] = [];
    for rec in recs {
        push(out, rec);
        let i = len(out) - 1;
        while i > 0 && (out[i - 1].priority > out[i].priority ||
                        (out[i - 1].priority == out[i].priority && out[i - 1].weight < out[i].weight)) {
            let t = out[i - 1];
            out[i - 1] = out[i];
            out[i] = t;
            i = i - 1;
        }
    }
    return out;
}

// The name `name` is an alias of, after every CNAME; `name` itself when
// it is not an alias.
pub fn lookup_cname(r: Resolver, name: str, deadline: until) -> result[str, str] {
    let lr = lookup(r, name, A, deadline);
    guard let recs = lr else let e = err_of(lr) {
        return err(e);
    }
    if len(recs) > 0 {
        return ok(recs[0].name);
    }
    let l6 = lookup(r, name, AAAA, deadline);
    guard let recs6 = l6 else let e = err_of(l6) {
        return err(e);
    }
    if len(recs6) > 0 {
        return ok(recs6[0].name);
    }
    return ok(canonical(name));
}

// Mail exchangers, by preference (lowest first). `value` is the host,
// `priority` its preference.
pub fn lookup_mx(r: Resolver, name: str, deadline: until) -> result[[Record], str] {
    let lr = lookup(r, name, MX, deadline);
    guard let recs = lr else let e = err_of(lr) {
        return err(e);
    }
    return ok(by_priority(recs));
}

// Service records for a full name such as "_imap._tcp.example.com", by
// priority (lowest first) and then weight (highest first). Choosing
// among one priority's records by weight, as RFC 2782 has a client do,
// is the caller's.
pub fn lookup_srv(r: Resolver, name: str, deadline: until) -> result[[Record], str] {
    let lr = lookup(r, name, SRV, deadline);
    guard let recs = lr else let e = err_of(lr) {
        return err(e);
    }
    return ok(by_priority(recs));
}

// Each TXT record's text, its strings joined.
pub fn lookup_txt(r: Resolver, name: str, deadline: until) -> result[[str], str] {
    return values(lookup(r, name, TXT, deadline));
}

pub fn lookup_ns(r: Resolver, name: str, deadline: until) -> result[[str], str] {
    return values(lookup(r, name, NS, deadline));
}

// The names an address points back to (PTR records).
pub fn lookup_addr(r: Resolver, ip: str, deadline: until) -> result[[str], str] {
    let nr = reverse_name(ip);
    guard let rname = nr else let e = err_of(nr) {
        return err(e);
    }
    return values(lookup(r, rname + ".", PTR, deadline));
}
