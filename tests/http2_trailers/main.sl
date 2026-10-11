import "http2";

fn check_response(body: bytes, label: str) -> int {
    let trailers: [http2.Header] = [
        http2.Header { name: "x-finish", value: "complete" }
    ];
    let msg = http2.response_trailers_msg(3, "200", [], body, trailers);
    let bad = 0;
    if msg.kind != http2.W_TRAILERS {
        println("FAIL " + label + ": wrong message kind");
        bad = bad + 1;
    }
    if msg.body != body {
        println("FAIL " + label + ": body changed");
        bad = bad + 1;
    }
    if msg.n <= 0 || msg.n >= len(msg.head) {
        println("FAIL " + label + ": missing header boundary");
        return bad + 1;
    }
    let hr = http2.decode(msg.head, 0, 16384);
    guard let hf = hr else let e = err_of(hr) {
        println("FAIL " + label + ": initial headers: " + e);
        return bad + 1;
    }
    if hf.ftype != http2.T_HEADERS || hf.stream != 3 {
        println("FAIL " + label + ": malformed initial headers frame");
        bad = bad + 1;
    }
    if (hf.flags & http2.FLAG_END_STREAM) != 0 {
        println("FAIL " + label + ": initial headers ended the stream");
        bad = bad + 1;
    }
    let tr = http2.decode(msg.head, msg.n, 16384);
    guard let tf = tr else let e = err_of(tr) {
        println("FAIL " + label + ": trailing headers: " + e);
        return bad + 1;
    }
    if tf.ftype != http2.T_HEADERS || tf.stream != 3 {
        println("FAIL " + label + ": malformed trailing headers frame");
        bad = bad + 1;
    }
    if tf.flags != (http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM) {
        println("FAIL " + label + ": trailing headers did not close the stream");
        bad = bad + 1;
    }
    let dr = http2.decode_block(http2.decoder_new(4096), tf.payload, 8);
    guard let decoded = dr else let e = err_of(dr) {
        println("FAIL " + label + ": trailer HPACK: " + e);
        return bad + 1;
    }
    if len(decoded) != 1 || decoded[0].name != "x-finish" ||
       decoded[0].value != "complete" {
        println("FAIL " + label + ": trailer fields changed");
        bad = bad + 1;
    }
    return bad;
}

let bad = check_response(b"reply", "body") +
          check_response(b"", "empty body");
if bad == 0 {
    println("all http2 trailer checks passed");
} else {
    println("FAILURES: ${bad}");
    exit(1);
}
