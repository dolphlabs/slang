// Unit tests: `slangc test stdlib/redis`. Pure protocol vectors only --
// the wire against a server is tested in tests/redis (a scripted fake
// server) and tests/live/redis (a real one) from later phases.

import "strings";

fn must_decode(buf: bytes) -> Reply {
    let r = decode(buf);
    guard let o = r else let e = err_of(r) {
        panic("decode failed: " + e);
    }
    guard let d = o else {
        panic("decode incomplete for a whole message");
    }
    return d.reply;
}

fn must_be_incomplete(buf: bytes) {
    let r = decode(buf);
    guard let o = r else let e = err_of(r) {
        panic("expected incomplete, got error: " + e);
    }
    guard let d = o else {
        return;
    }
    panic("expected incomplete, decoded kind " + to_str(d.reply.kind));
}

fn must_be_corrupt(buf: bytes, want: str) {
    let r = decode(buf);
    guard let o = r else let e = err_of(r) {
        if strings.contains(e, want) {
            return;
        }
        panic("wrong corrupt message: " + e);
    }
    guard let d = o else {
        panic("expected corrupt, got incomplete");
    }
    panic("expected corrupt, decoded kind " + to_str(d.reply.kind));
}

fn bulk_of(r: Reply) -> bytes {
    guard let b = r.bulk else {
        panic("expected bulk data");
    }
    return b;
}

fn test_encode_vectors() {
    assert(encode([to_bytes("PING")]) == b"*1\r\n$4\r\nPING\r\n",
           "PING encoding");
    assert(encode([to_bytes("SET"), to_bytes("k"),
                   to_bytes("v")]) == b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n",
           "SET encoding");
    // binary-safe: NUL, CR, LF and high bytes pass through untouched
    let raw = b"a\x00b\r\nc\xff";
    let enc = encode([raw]);
    assert(enc == b"*1\r\n$7\r\n" + raw + b"\r\n", "binary encoding");
    // empty bulk argument is a zero length, not an absence
    assert(encode([b""]) == b"*1\r\n$0\r\n\r\n", "empty arg encoding");
}

fn test_decode_types() {
    let s = must_decode(b"+OK\r\n");
    assert(s.kind == REPLY_SIMPLE && s.text == "OK", "simple string");

    let e = must_decode(b"-WRONGTYPE bad kind\r\n");
    assert(e.kind == REPLY_ERROR, "error kind");

    let i = must_decode(b":42\r\n");
    assert(i.kind == REPLY_INT && i.num == 42, "positive int");
    let n = must_decode(b":-7\r\n");
    assert(n.kind == REPLY_INT && n.num == 0 - 7, "negative int");

    let b = must_decode(b"$3\r\nfoo\r\n");
    assert(b.kind == REPLY_BULK && bulk_of(b) == b"foo", "bulk");

    let nil = must_decode(b"$-1\r\n");
    assert(nil.kind == REPLY_BULK, "nil bulk kind");
    assert((nil.bulk ?? b"nil-marker") == b"nil-marker", "nil bulk is none");

    let a = must_decode(b"*2\r\n$3\r\nfoo\r\n:1\r\n");
    assert(a.kind == REPLY_ARRAY && len(a.items) == 2, "array shape");
    assert(a.items[0].kind == REPLY_BULK, "array elem 0");
    assert(a.items[1].num == 1, "array elem 1");

    let empty = must_decode(b"*0\r\n");
    assert(empty.kind == REPLY_ARRAY && len(empty.items) == 0 &&
           !empty.is_nil, "empty array");

    let nilarr = must_decode(b"*-1\r\n");
    assert(nilarr.kind == REPLY_ARRAY && nilarr.is_nil, "nil array");

    let nested = must_decode(b"*2\r\n*2\r\n:1\r\n:2\r\n*0\r\n");
    assert(len(nested.items) == 2 &&
           len(nested.items[0].items) == 2, "nested array");
}

fn test_decode_incomplete() {
    let whole = b"*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n";
    let cuts = [0, 1, 2, 5, 8, 13, 16, 21, len(whole) - 1];
    for c in cuts {
        must_be_incomplete(whole[..c]);
    }
    must_be_incomplete(b"");
    must_be_incomplete(b"$5\r\nabc");
}

fn test_decode_corrupt() {
    must_be_corrupt(b"+OK\n", "bad control line");
    must_be_corrupt(b"%1\r\n", "unknown reply type");
}

fn test_decode_bad_shapes() {
    must_be_corrupt(b"$x\r\n", "bad bulk length");
    must_be_corrupt(b"$-2\r\n", "negative bulk length");
    must_be_corrupt(b"*-2\r\n", "negative array length");
    must_be_corrupt(b"*x\r\n", "bad array length");
    must_be_corrupt(b":12x\r\n", "bad integer");
    must_be_corrupt(b"$3\r\nabcXX", "missing trailing CRLF");
    must_be_corrupt(b":9223372036854775808\r\n", "out of range");
    must_be_corrupt(b":-9223372036854775809\r\n", "out of range");
    // over-limit lengths fail before the bytes are even needed
    must_be_corrupt(b"$268435457\r\n", "exceeds limit");
    must_be_corrupt(b"*1000001\r\n", "element limit");
    // 33 nested arrays breach MAX_DEPTH
    let deep = b"";
    let i = 0;
    while i < 33 {
        deep = deep + b"*1\r\n";
        i = i + 1;
    }
    deep = deep + b":1\r\n";
    must_be_corrupt(deep, "nesting");
}

fn test_int_edges() {
    let mx = must_decode(b":9223372036854775807\r\n");
    assert(mx.num == 9223372036854775807, "int max");
    let mn = must_decode(b":-9223372036854775808\r\n");
    assert(mn.num == 0 - 9223372036854775808, "int min");
}

fn test_roundtrip() {
    let args = [to_bytes("SET"), to_bytes("k"), b"v\x00v"];
    let d = must_decode(encode(args));
    assert(d.kind == REPLY_ARRAY, "roundtrip shape");
}

fn test_slot_vectors() {
    // foo -> 12182 is the worked example in the Redis docs
    assert(slot("foo") == 12182, "slot foo");
    assert(slot("hello") == 866, "slot hello");
    // hash tags colocate: both hash "user1000" -> 3443
    assert(slot("{user1000}.following") == 3443, "tag a");
    assert(slot("{user1000}.followers") == 3443, "tag b");
    // empty tags hash the whole key, a lone { is literal
    assert(slot("{}foo") == 9500, "empty tag");
    assert(slot("abc{def") == 2899, "unclosed brace");
}

fn cfg_of(url: str) -> Config {
    let r = parse_url(url);
    guard let c = r else let e = err_of(r) {
        panic("parse_url(" + url + "): " + e);
    }
    return c;
}

fn test_parse_url_full() {
    let c = cfg_of("redis://alice:p%3Ass@db.example.com:6380/2");
    assert(c.username == "alice", "user");
    assert(c.password == "p:ss", "pass");
    assert(c.host == "db.example.com", "host");
    assert(c.port == 6380, "port");
    assert(c.db == 2, "db");
    assert(c.sslmode == "disable", "sslmode");
}

fn test_parse_url_defaults() {
    let c = cfg_of("redis://localhost");
    assert(c.host == "localhost", "host");
    assert(c.port == 6379, "default port");
    assert(c.db == 0, "default db");
    assert(c.password == "", "no password");
    let t = cfg_of("rediss://db.example.com");
    assert(t.sslmode == "require", "rediss forces tls");
    assert(t.port == 6379, "tls default port");
}

fn url_error(url: str) -> str {
    let r = parse_url(url);
    guard let c = r else let e = err_of(r) {
        return e;
    }
    panic("parse_url(" + url + ") should have failed");
}

fn test_parse_url_refusals() {
    assert(strings.contains(url_error("http://x"), "redis://"),
           "scheme");
    assert(strings.contains(url_error("redis://"), "host"), "no host");
    assert(strings.contains(url_error("redis://h:notaport"), "port"),
           "bad port");
    assert(strings.contains(url_error("redis://h:0"), "range"),
           "port range");
    assert(strings.contains(url_error("redis://h/-1"), "negative"),
           "negative db");
    assert(strings.contains(url_error("redis://h/x"), "number"),
           "nan db");
    assert(strings.contains(url_error("redis://h?sslmode=yes"), "sslmode"),
           "bad sslmode");
    assert(strings.contains(url_error("rediss://h?sslmode=disable"),
                            "contradicts"), "tls contradiction");
}
