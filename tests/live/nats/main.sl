// The nats client against a REAL nats-server. Not part of `make test`; CI
// runs it against service containers, and locally:
//
//   docker run -d -p 54222:4222 nats:2.10-alpine
//   docker run -d -p 54223:4222 nats:2.10-alpine --user alice --pass s3cret
//   docker run -d -p 54224:4222 nats:2.10-alpine --auth tok123
//   docker run -d -p 54225:4222 -v $PWD/tests/live/nats/nkey.conf:/nkey.conf:ro \
//       nats:2.10-alpine -c /nkey.conf
//   NATS_URL=nats://127.0.0.1:54222 ./slangc tests/live/nats/main.sl --run
//
// NATS_USERPASS_URL, NATS_TOKEN_URL and NATS_NKEY_URL, when set, are the
// servers requiring each kind of authentication; NATS_TLS_URL (with
// NATS_TLS_CA, the CA that signed its certificate) one that requires TLS.

import "nats";
import "proc";
import "strings";
import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

fn conn(url: str) -> nats.Conn {
    let r = nats.connect(url, soon());
    guard let nc = r else let e = err_of(r) {
        die("connect " + url + ": " + e);
        return nats.connect(url, soon()) ?? panic_conn();
    }
    return nc;
}

fn panic_conn() -> nats.Conn {
    panic("unreachable");
}

fn sub(nc: nats.Conn, subject: str) -> nats.Sub {
    let r = nats.subscribe(nc, subject);
    guard let s = r else let e = err_of(r) { panic(e); }
    return s;
}

fn next(s: nats.Sub) -> nats.Msg {
    let r = nats.next_msg(s, soon());
    guard let om = r else let e = err_of(r) { panic(e); }
    guard let m = om else { die("no message on " + s.subject); panic("x"); }
    return m;
}

fn responder(nc: nats.Conn, s: nats.Sub) {
    while true {
        let r = nats.next_msg(s, until_of(time.mono() + 10000000000));
        guard let om = r else { return; }
        guard let m = om else { return; }
        nats.respond(nc, m, to_bytes("re:" + to_str(m.data)));
    }
}

let url = proc.getenv("NATS_URL") ?? "nats://127.0.0.1:54222";
let nc = conn(url);

// ---- publish and subscribe ---------------------------------------------------
let s1 = sub(nc, "live.basic");
nats.flush(nc, soon());
nats.publish(nc, "live.basic", b"hello");
nats.publish(nc, "live.basic", b"");
let big = strings.bytes_zero(1000000);
big[999999] = 7;
nats.publish(nc, "live.basic", big);
let m1 = next(s1);
let m2 = next(s1);
let m3 = next(s1);
if to_str(m1.data) != "hello" || len(m2.data) != 0 || len(m3.data) != 1000000 || m3.data[999999] != 7 {
    die("payloads");
}
println("ok publish and subscribe (empty and 1 MB payloads)");

// ---- wildcards -----------------------------------------------------------------
let star = sub(nc, "live.w.*");
let tail = sub(nc, "live.w.>");
nats.flush(nc, soon());
nats.publish(nc, "live.w.a", b"1");
nats.publish(nc, "live.w.a.b", b"2");
if to_str(next(star).data) != "1" || to_str(next(tail).data) != "1" || to_str(next(tail).data) != "2" {
    die("wildcards");
}
let none_left = nats.next_msg(star, until_of(time.mono() + 200000000)) ?? none;
if let x = none_left { die("* matched two tokens"); }
println("ok wildcards");

// ---- queue groups ----------------------------------------------------------------
let qa = nats.queue_subscribe(nc, "live.q", "workers") ?? s1;
let qb = nats.queue_subscribe(nc, "live.q", "workers") ?? s1;
nats.flush(nc, soon());
for i in 0..200 {
    nats.publish(nc, "live.q", to_bytes(to_str(i)));
}
nats.flush(nc, soon());
let got = 0;
for q in [qa, qb] {
    while true {
        let r = nats.next_msg(q, until_of(time.mono() + 300000000)) ?? none;
        guard let _m = r else { break; }
        got += 1;
    }
}
if got != 200 {
    die("queue group delivered " + to_str(got) + " of 200");
}
println("ok queue group shares the messages");

// ---- headers ---------------------------------------------------------------------
let hs = sub(nc, "live.h");
nats.flush(nc, soon());
let h: map[str][str] = {};
h["Trace-Id"] = ["abc"];
h["Tag"] = ["one", "two"];
nats.publish_headers(nc, "live.h", h, b"with headers");
let hm = next(hs);
if to_str(hm.data) != "with headers" || (hm.headers["Trace-Id"])[0] != "abc" || len(hm.headers["Tag"]) != 2 {
    die("headers");
}
println("ok headers, several values per key");

// ---- request/reply -----------------------------------------------------------------
let svc = sub(nc, "live.echo");
nats.flush(nc, soon());
spawn responder(nc, svc);
let rr = nats.request(nc, "live.echo", b"ping", soon());
guard let reply = rr else let e = err_of(rr) { die("request: " + e); panic("x"); }
if to_str(reply.data) != "re:ping" {
    die("reply data");
}
for i in 0..50 {
    let r = nats.request(nc, "live.echo", to_bytes(to_str(i)), soon());
    guard let rm = r else let e = err_of(r) { die("request " + to_str(i) + ": " + e); panic("x"); }
    if to_str(rm.data) != "re:" + to_str(i) {
        die("reply " + to_str(i));
    }
}
let t0 = time.mono();
let nr = nats.request(nc, "live.nobody", b"x", soon());
if let _m = nr { die("a request with no responders got a reply"); }
if !strings.contains(err_of(nr), "no responders") || ((time.mono() - t0) as int) > 2000000000 {
    die("no responders: " + err_of(nr));
}
println("ok request/reply, and no responders fails fast");

// ---- auto-unsubscribe, deadlines, slow consumers ------------------------------------
let au = sub(nc, "live.au");
nats.auto_unsubscribe(au, 3);
nats.flush(nc, soon());
for i in 0..10 {
    nats.publish(nc, "live.au", b"x");
}
nats.flush(nc, soon());
let n = 0;
while true {
    let r = nats.next_msg(au, until_of(time.mono() + 300000000)) ?? none;
    guard let _m = r else { break; }
    n += 1;
}
if n != 3 {
    die("auto_unsubscribe delivered " + to_str(n));
}
let quiet = sub(nc, "live.quiet");
let t1 = time.mono();
let qr = nats.next_msg(quiet, until_of(time.mono() + 250000000)) ?? none;
let waited = ((time.mono() - t1) as int) / 1000000;
if let _m = qr { die("message from nowhere"); }
if waited < 240 || waited > 600 {
    die("next_msg deadline took " + to_str(waited) + " ms");
}
let opts = nats.options(url);
opts.pending = 10;
let small_r = nats.connect_with(opts, soon());
guard let small = small_r else let e = err_of(small_r) { die(e); panic("x"); }
let slow = sub(small, "live.slow");
nats.flush(small, soon());
for i in 0..100 {
    nats.publish(nc, "live.slow", b"x");
}
nats.flush(nc, soon());
nats.flush(small, soon());
if slow.dropped == 0 {
    die("a slow consumer dropped nothing");
}
nats.close(small);
println("ok auto-unsubscribe, deadlines and slow consumers");

// ---- authentication ------------------------------------------------------------------
let up = proc.getenv("NATS_USERPASS_URL") ?? "";
if up != "" {
    let bad = nats.connect(strings.replace(up, "s3cret", "wrong"), soon());
    if let _c = bad { die("a wrong password connected"); }
    let good = conn(up);
    nats.close(good);
    println("ok user and password (and a wrong one refused: " + err_of(bad) + ")");
}
let tok = proc.getenv("NATS_TOKEN_URL") ?? "";
if tok != "" {
    let good = conn(tok);
    nats.close(good);
    println("ok token");
}
let nk = proc.getenv("NATS_NKEY_URL") ?? "";
if nk != "" {
    let no = nats.connect(nk, soon());
    if let _c = no { die("an nkey server let us in without a key"); }
    let o = nats.options(nk);
    o.nkey_seed = nats.nkey_encode_seed(b"nkey-test-seed-for-live-tests-01") ?? "";
    let r = nats.connect_with(o, soon());
    guard let c = r else let e = err_of(r) { die("nkey: " + e); panic("x"); }
    let ns = sub(c, "live.nk");
    nats.flush(c, soon());
    nats.publish(c, "live.nk", b"signed in");
    if to_str(next(ns).data) != "signed in" {
        die("nkey connection");
    }
    nats.close(c);
    println("ok nkey (signed nonce)");
}

let tls_url = proc.getenv("NATS_TLS_URL") ?? "";
if tls_url != "" {
    let o = nats.options(tls_url);
    o.ca_path = proc.getenv("NATS_TLS_CA") ?? "";
    let r = nats.connect_with(o, soon());
    guard let c = r else let e = err_of(r) { die("tls: " + e); panic("x"); }
    let ts = sub(c, "live.tls");
    nats.flush(c, soon());
    nats.publish(c, "live.tls", b"over tls");
    if to_str(next(ts).data) != "over tls" {
        die("tls round trip");
    }
    nats.close(c);
    // the same server without TLS from the client side is refused clearly
    let plain = nats.connect(strings.replace(tls_url, "tls://", "nats://"), soon());
    if let _p = plain { die("connected in cleartext to a TLS-only server"); }
    println("ok tls with a verified certificate (cleartext refused: " + err_of(plain) + ")");
}

let dr = nats.drain(nc, soon());
guard let _d = dr else let e = err_of(dr) { die("drain: " + e); panic("x"); }
if nats.is_connected(nc) {
    die("still connected after drain");
}
println("ok drain");
