import "http2";

// HTTP/2 frame layer and HPACK.
//
// The nghttp2 fixtures below are real HPACK blocks captured from
// nghttp2's deflater (the encoder curl and the browser stacks use), so
// these assertions are interop checks against an independent
// implementation rather than self-consistency. They are baked in as
// literals so the suite needs no nghttp2 at run time.


// Interop: every block below was produced by nghttp2's real HPACK
// deflater -- the encoder curl and the browser stacks use -- not by this
// package. Decoding them exercises indexed fields, literals with and
// without indexing, dynamic-table insertion, and Huffman-coded strings
// against a fully independent implementation.

fn chk(tag: str, h: http2.Header, name: str, value: str) -> int {
    if h.name != name {
        println("FAIL " + tag + ": name " + h.name + " want " + name);
        return 1;
    }
    if h.value != value {
        println("FAIL " + tag + ": value [" + h.value + "] want [" + value + "]");
        return 1;
    }
    return 0;
}

fn case_simple_get() -> int {
    let bad = 0;
    let d = http2.decoder_new(4096);
    let r = http2.decode_block(d, b"\x82\x87\x84\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff", 64);
    guard let hs = r else let e = err_of(r) {
        println("FAIL simple_get: " + e);
        return 1;
    }
    if len(hs) != 4 {
        println("FAIL simple_get: got ${len(hs)} headers, want 4");
        return 1;
    }
    bad = bad + chk("simple_get", hs[0], ":method", "GET");
    bad = bad + chk("simple_get", hs[1], ":scheme", "https");
    bad = bad + chk("simple_get", hs[2], ":path", "/");
    bad = bad + chk("simple_get", hs[3], ":authority", "www.example.com");
    return bad;
}

fn case_post_with_ua() -> int {
    let bad = 0;
    let d = http2.decoder_new(4096);
    let r = http2.decode_block(d, b"\x83\x87\x04\x9a\x60\x75\x99\x8e\xe1\x62\xd4\x16\xc4\x7f\x92\x9a\x84\x96\xc8\x06\x44\x9b\xb9\x7e\x28\x35\x26\x4c\x0d\x83\x41\x8b\x1d\x66\x5c\xbe\x47\x4d\x74\x15\x72\x1e\x9f\x7a\xa6\x25\xb6\x50\xc3\xcb\xba\xb8\x54\xfe\xbc\xbc\xe4\x4e\x34\xb0\xeb\xae\x82\xad\x20\xec\xf0\x6a\x84\xd2\xe0\xfe\xd4\xa0\xd1\x92\xdb\x28\x61\xe5\xdd\x5c\x3f\x53\x03\x2a\x2f\x2a\x5f\x8b\x1d\x75\xd0\x62\x0d\x26\x3d\x4c\x74\x41\xea\x40\x89\xf2\xb5\x85\xed\x69\x50\x95\x8d\x27\x9a\x04\xaf\x4a\x39\x1b\x8d\x69\x1f\x24\x6b\x34\xe3\xf2\xac\x30\xb8\xda\xce\x81\xe7\x1d\x74\x4f\x3e\xd8\x0b", 64);
    guard let hs = r else let e = err_of(r) {
        println("FAIL post_with_ua: " + e);
        return 1;
    }
    if len(hs) != 8 {
        println("FAIL post_with_ua: got ${len(hs)} headers, want 8");
        return 1;
    }
    bad = bad + chk("post_with_ua", hs[0], ":method", "POST");
    bad = bad + chk("post_with_ua", hs[1], ":scheme", "https");
    bad = bad + chk("post_with_ua", hs[2], ":path", "/api/v1/users?filter=active&limit=50");
    bad = bad + chk("post_with_ua", hs[3], ":authority", "api.example.com");
    bad = bad + chk("post_with_ua", hs[4], "user-agent", "curl/8.7.1 (x86_64-apple-darwin24.0) libcurl/8.7.1");
    bad = bad + chk("post_with_ua", hs[5], "accept", "*/*");
    bad = bad + chk("post_with_ua", hs[6], "content-type", "application/json");
    bad = bad + chk("post_with_ua", hs[7], "x-request-id", "0f8fad5b-d9cb-469f-a165-70867728950e");
    return bad;
}

fn case_punctuation() -> int {
    let bad = 0;
    let d = http2.decoder_new(4096);
    let r = http2.decode_block(d, b"\x40\x86\xf2\xb5\x76\xd4\x44\xff\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x3a\x3b\x3c\x3d\x3e\x3f\x40\x5b\x5c\x5d\x5e\x5f\x60\x7b\x7c\x7d\x7e\x40\x86\xf2\xb4\x86\x98\xc9\x47\x88\x00\x44\xcb\x4d\xb8\xeb\xcf\xff\x40\x86\xf2\xb5\x26\xf2\x59\x3f\x96\x86\x3b\xd2\x60\x97\x14\xf9\x3a\x66\xa3\x45\x5a\xab\xd9\x66\xe4\xf0\xef\xcb\xcf\x3f\x7f", 64);
    guard let hs = r else let e = err_of(r) {
        println("FAIL punctuation: " + e);
        return 1;
    }
    if len(hs) != 3 {
        println("FAIL punctuation: got ${len(hs)} headers, want 3");
        return 1;
    }
    bad = bad + chk("punctuation", hs[0], "x-punct", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
    bad = bad + chk("punctuation", hs[1], "x-digits", "0123456789");
    bad = bad + chk("punctuation", hs[2], "x-mixed", "AbCdEfGhIjKlMnOpQrStUvWxYz");
    return bad;
}

fn case_response() -> int {
    let bad = 0;
    let d = http2.decoder_new(4096);
    let r = http2.decode_block(d, b"\x88\x5f\x92\x49\x7c\xa5\x89\xd3\x4d\x1f\x6a\x12\x71\xd8\x82\xa6\x0b\x53\x2a\xcf\x7f\x0f\x0d\x83\x08\x99\x6b\x76\x84\x45\x03\xaa\x6f", 64);
    guard let hs = r else let e = err_of(r) {
        println("FAIL response: " + e);
        return 1;
    }
    if len(hs) != 4 {
        println("FAIL response: got ${len(hs)} headers, want 4");
        return 1;
    }
    bad = bad + chk("response", hs[0], ":status", "200");
    bad = bad + chk("response", hs[1], "content-type", "text/html; charset=utf-8");
    bad = bad + chk("response", hs[2], "content-length", "1234");
    bad = bad + chk("response", hs[3], "server", "slang");
    return bad;
}




// ---- frame header codec -------------------------------------------
fn frames() -> int {
    let bad = 0;
    let payload = b"";
    for i in 0..300 { payload = payload + b"\x41"; }
    let full = http2.header_bytes(http2.T_HEADERS, http2.FLAG_END_HEADERS, 5, 300)
             + payload;
    let dr = http2.decode(full, 0, 16384);
    guard let f = dr else let e = err_of(dr) {
        println("FAIL frame decode: " + e);
        return 1;
    }
    if f.ftype != http2.T_HEADERS { println("FAIL ftype"); bad = bad + 1; }
    if f.flags != http2.FLAG_END_HEADERS { println("FAIL flags"); bad = bad + 1; }
    if f.stream != 5 { println("FAIL stream"); bad = bad + 1; }
    if len(f.payload) != 300 { println("FAIL plen"); bad = bad + 1; }

    // the reserved bit must be ignored, not folded into the stream id
    let r = http2.header_bytes(http2.T_DATA, 0, 7, 0);
    r[5] = 0x80;
    let dr3 = http2.decode(r, 0, 16384);
    guard let f3 = dr3 else { println("FAIL reserved"); return bad + 1; }
    if f3.stream != 7 { println("FAIL reserved bit leaked: ${f3.stream}"); bad = bad + 1; }

    // a length past SETTINGS_MAX_FRAME_SIZE is refused before allocating
    let big = http2.header_bytes(http2.T_DATA, 0, 1, 100000);
    let dr4 = http2.decode(big, 0, 16384);
    guard let f4 = dr4 else let e = err_of(dr4) {
        // expected
        let pr = http2.strip_padding(b"\x03hello\x00\x00\x00", http2.FLAG_PADDED);
        guard let stripped = pr else { println("FAIL pad"); return bad + 1; }
        if stripped != b"hello" { println("FAIL padding strip"); bad = bad + 1; }
        return bad;
    }
    println("FAIL oversize frame was accepted");
    return bad + 1;
}

// ---- HPACK integers, incl. the RFC 7541 C.1 vectors ---------------
fn integers() -> int {
    let bad = 0;
    for v in [0, 1, 10, 30, 31, 32, 127, 128, 255, 256, 1337, 100000] {
        let e5 = http2.write_int(v, 5, 0x00);
        let r5 = http2.read_int(e5, 0, 5);
        guard let g5 = r5 else { println("FAIL int5 ${v}"); bad = bad + 1; continue; }
        if g5.value != v || g5.next != len(e5) {
            println("FAIL int5 ${v} -> ${g5.value}");
            bad = bad + 1;
        }
        let e7 = http2.write_int(v, 7, 0x00);
        let r7 = http2.read_int(e7, 0, 7);
        guard let g7 = r7 else { println("FAIL int7 ${v}"); bad = bad + 1; continue; }
        if g7.value != v { println("FAIL int7 ${v}"); bad = bad + 1; }
    }
    // C.1.1: 10 in a 5-bit prefix is the single octet 0x0a
    let c1 = http2.write_int(10, 5, 0x00);
    if len(c1) != 1 || c1[0] != 0x0a { println("FAIL RFC C.1.1"); bad = bad + 1; }
    // C.1.2: 1337 in a 5-bit prefix is 31, 154, 10
    let c2 = http2.write_int(1337, 5, 0x00);
    if len(c2) != 3 || c2[0] != 31 || c2[1] != 154 || c2[2] != 10 {
        println("FAIL RFC C.1.2");
        bad = bad + 1;
    }
    return bad;
}

// ---- every Huffman symbol -----------------------------------------
fn huffman() -> int {
    let bad = 0;
    let h = http2.huff_new();
    let hcases: [bytes] = [];
    let hwant: [bytes] = [];
    hcases = hcases + [b"\xff\xc7\xff\xfd\x8f\xff\xff\xe2\xff\xff\xfe\x3f\xff\xff\xe4\xff\xff\xfe\x5f\xff\xff\xe6\xff\xff\xfe\x7f\xff\xff\xe8\xff\xff\xea\xff\xff\xff\xf3\xff\xff\xfa\x7f\xff\xff\xab\xff\xff\xff\xdf\xff\xff\xeb\xff\xff\xfe\xcf\xff\xff\xed\xff\xff\xfe\xef\xff\xff\xef\xff\xff\xff\x0f\xff\xff\xf1\xff\xff\xff\x2f\xff\xff\xff\xbf\xff\xff\xcf\xff\xff\xfd\x3f\xff\xff\xd7\xff\xff\xfd\xbf\xff\xff\xdf\xff\xff\xfe\x3f\xff\xff\xe7\xff\xff\xfe\xbf\xff\xff\xef"];
    hwant = hwant + [b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"];
    hcases = hcases + [b"\x53\xf8\xfe\x7f\xeb\xff\x2a\xfc\x7f\xaf\xeb\xfb\xf9\xff\x7f\x4b\x2e\xc0\x02\x26\x5a\x6d\xc7\x5e\x7e\xe7\xdf\xff\xc8\x3f\xef\xfc"];
    hwant = hwant + [b"\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f"];
    hcases = hcases + [b"\xff\xd4\x37\x6f\x5f\xc1\x87\x16\x3c\x99\x73\x67\xd1\xa7\x56\xbd\x9b\x77\x6f\xe1\xc7\x97\xe7\x3f\xdf\xfd\xff\xff\x0f\xfe\x7f\xf9\x17"];
    hwant = hwant + [b"\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f"];
    hcases = hcases + [b"\xff\xfa\x38\xc9\x21\x65\x9a\x73\x74\xeb\x45\x35\x1e\xbe\xd6\x21\x36\xf7\xf1\xe7\xd7\xbf\xff\xdf\xf3\xff\xdf\xfe\xff\xff\xff\xe7"];
    hwant = hwant + [b"\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f"];
    hcases = hcases + [b"\xff\xfe\x6f\xff\xf4\xbf\xff\x9f\xff\xfa\x3f\xff\xd3\xff\xff\x53\xff\xfd\x5f\xff\xfb\x3f\xff\xeb\x7f\xff\xda\xff\xff\xb7\xff\xff\x73\xff\xfe\xef\xff\xfd\xef\xff\xfe\xbf\xff\xfb\xff\xff\xfd\x9f\xff\xfd\xbf\xff\xeb\xff\xff\xe0\xff\xff\xee\xff\xff\xc3\xff\xff\x8b\xff\xff\x1f\xff\xfe\x4f\xff\xee\x7f\xff\xb1\xff\xff\x97\xff\xfd\x9f\xff\xfc\xdf\xff\xf9\xff\xff\xfb\xff"];
    hwant = hwant + [b"\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f"];
    hcases = hcases + [b"\xff\xff\x6b\xff\xfb\xbf\xff\xd3\xff\xfe\xdf\xff\xfb\x9f\xff\xfa\x3f\xff\xf4\xff\xff\x7b\xff\xff\x57\xff\xfb\xbf\xff\xef\x7f\xff\xf8\x7f\xff\x7f\xff\xfd\xff\xff\xfd\x7f\xff\xfb\x3f\xff\xc1\xff\xfe\x1f\xff\xf8\x3f\xff\xc5\xff\xff\xb7\xff\xfe\x1f\xff\xfd\xdf\xff\xfb\xff\xff\xab\xff\xfe\x2f\xff\xf8\xff\xff\xe4\xff\xff\xe1\xff\xff\x2f\xff\xfc\xdf\xff\xfc\x7f"];
    hwant = hwant + [b"\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf"];
    hcases = hcases + [b"\xff\xff\xf8\x3f\xff\xfe\x1f\xff\xeb\xff\xfe\x3f\xff\xf3\xff\xff\xf2\xff\xff\xa3\xff\xff\xd9\xff\xff\xf1\x7f\xff\xfc\x7f\xff\xff\x27\xff\xff\xde\xff\xff\xfb\xff\xff\xff\x2f\xff\xff\x8f\xff\xff\xb7\xff\xf9\x7f\xff\x8f\xff\xff\xe6\xff\xff\xfc\x1f\xff\xff\x87\xff\xff\xe7\xff\xff\xfc\x5f\xff\xfe\x5f\xff\xe4\xff\xff\x2f\xff\xff\xd1\xff\xff\xf4\xff\xff\xff\xef\xff\xff\xe3\xff\xff\xfc\x9f\xff\xff\x97"];
    hwant = hwant + [b"\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf"];
    hcases = hcases + [b"\xff\xfe\xcf\xff\xff\x3f\xff\xed\xff\xff\x37\xff\xfd\x3f\xff\xe7\xff\xff\x47\xff\xff\x3f\xff\xfa\xbf\xff\xeb\xff\xff\xf7\x7f\xff\xfb\xff\xff\xfd\x3f\xff\xfd\x7f\xff\xfe\xaf\xff\xfe\x9f\xff\xff\x5f\xff\xff\xe6\xff\xff\xfb\x3f\xff\xfe\xdf\xff\xff\xcf\xff\xff\xfa\x3f\xff\xff\x4f\xff\xff\xea\xff\xff\xfd\x7f\xff\xff\xfd\xff\xff\xfb\x3f\xff\xff\x6f\xff\xff\xee\xff\xff\xfd\xff\xff\xff\xc3\xff\xff\xee"];
    hwant = hwant + [b"\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff"];
    for i in 0..len(hcases) {
        let r = http2.huff_decode(h, hcases[i]);
        guard let got = r else let e = err_of(r) {
            println("FAIL huffman chunk ${i}: " + e);
            bad = bad + 1;
            continue;
        }
        if got != hwant[i] {
            println("FAIL huffman chunk ${i}: mismatch");
            bad = bad + 1;
        }
    }
    // symbol 0 is NUL: decoding must yield bytes, not a str truncated there
    let z = http2.huff_decode(h, hcases[0]);
    guard let zb = z else { println("FAIL nul chunk"); return bad + 1; }
    if len(zb) != 32 { println("FAIL NUL truncation: ${len(zb)} bytes"); bad = bad + 1; }
    // EOS must never appear inside a header string
    let eos = http2.huff_decode(h, b"\xff\xff\xff\xff\xff\xff\xff\xff");
    guard let ev = eos else let e = err_of(eos) { return bad; }
    println("FAIL EOS accepted");
    return bad + 1;
}

// ---- our own encoder decodes back ---------------------------------
fn encode_roundtrip() -> int {
    let bad = 0;
    let hs: [http2.Header] = [
        http2.Header { name: ":status", value: "200" },
        http2.Header { name: "content-type", value: "text/html; charset=utf-8" },
        http2.Header { name: "server", value: "slang" },
        http2.Header { name: "x-trace", value: "a!b#c$d%e&f'g(h)" }
    ];
    let blk = http2.encode_block(hs);
    let d = http2.decoder_new(4096);
    let r = http2.decode_block(d, blk, 64);
    guard let got = r else let e = err_of(r) {
        println("FAIL encode round-trip: " + e);
        return 1;
    }
    if len(got) != len(hs) {
        println("FAIL round-trip count ${len(got)}");
        return 1;
    }
    for i in 0..len(hs) {
        bad = bad + chk("roundtrip", got[i], hs[i].name, hs[i].value);
    }
    return bad;
}

// ---- malformed input is rejected, never accepted silently ---------
fn malformed() -> int {
    let bad = 0;
    let d = http2.decoder_new(4096);
    // index 0 is not a valid header index
    let a = http2.decode_block(d, b"\x80", 64);
    guard let av = a else let e = err_of(a) {
        // an index past the end of both tables
        let b2 = http2.decode_block(d, b"\xfe", 64);
        guard let bv = b2 else let e2 = err_of(b2) {
            // a size update above the agreed maximum
            let c = http2.decode_block(d, b"\x3f\xe1\xff\xff\xff\x07", 64);
            guard let cv = c else let e3 = err_of(c) {
                return bad;
            }
            println("FAIL oversized table update accepted");
            return bad + 1;
        }
        println("FAIL out-of-range index accepted");
        return bad + 1;
    }
    println("FAIL index 0 accepted");
    return bad + 1;
}

let bad = 0;
bad = bad + frames();
bad = bad + integers();
bad = bad + huffman();
bad = bad + encode_roundtrip();
bad = bad + malformed();
bad = bad + case_simple_get();
bad = bad + case_post_with_ua();
bad = bad + case_punctuation();
bad = bad + case_response();

if bad == 0 {
    println("all http2 checks passed");
} else {
    println("FAILURES: ${bad}");
    exit(1);
}
