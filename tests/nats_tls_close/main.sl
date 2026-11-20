// nats over TLS, connected and closed by several tasks at once against a
// scripted server in the same program. Closing a TLS connection must
// close its socket exactly once: net.tls_close already closes the fd, so
// a second net.close on the same number can close a socket another
// worker has just opened with it (a dial, or the server's accept), and
// that connection then fails. Every connection here must succeed.

import "crypto";
import "fs";
import "nats";
import "net";
import "os";
import "strings";
import "time";
import "x509";

fn soon() -> until {
    return until_of(time.mono() + 10000000000);
}

fn put(c: &mut link, s: str) -> bool {
    let data = to_bytes(s);
    let a = arena_new(len(data) + 64);
    let out = a.wire(len(data));
    for i in 0..len(data) {
        out[i] = data[i];
    }
    let r = c.send(out, soon());
    guard let _n = r else { return false; }
    return true;
}

// Reads until `want` has arrived; false if the client went away first.
fn wait_for(c: &mut link, want: str) -> bool {
    let a = arena_new(8192);
    let buf = a.wire(4096);
    let have = "";
    while !strings.contains(have, want) {
        let r = c.recv(buf, soon());
        guard let n = r else { return false; }
        if n == 0 {
            return false;
        }
        have = have + to_str(to_bytes(buf[0..n]));
    }
    return true;
}

fn serve_one(c: link, ctx: rawptr, fails: chan[str]) {
    let mc = c;
    if !put(&mut mc, "INFO {\"server_id\":\"fake\",\"max_payload\":1048576,\"tls_required\":true}\r\n") {
        chan_send(fails, "server: INFO not sent");
        return;
    }
    let hr = mc.tls_accept(ctx, soon());
    guard let _h = hr else let e = err_of(hr) {
        chan_send(fails, "server: handshake: " + to_str(e));
        return;
    }
    if !wait_for(&mut mc, "PING\r\n") {
        chan_send(fails, "server: no CONNECT and PING");
        return;
    }
    put(&mut mc, "PONG\r\n");
    // Until the client closes.
    let a = arena_new(8192);
    let buf = a.wire(4096);
    while true {
        let r = mc.recv(buf, soon());
        guard let n = r else { return; }
        if n == 0 {
            return;
        }
    }
}

fn server(ln: link, ctx: rawptr, total: int, fails: chan[str]) {
    let l = ln;
    for _i in 0..total {
        let ar = l.accept(soon());
        guard let c = ar else let e = err_of(ar) {
            chan_send(fails, "server: accept: " + to_str(e));
            continue;
        }
        spawn serve_one(c, ctx, fails);
    }
}

fn churn(url: str, ca: str, rounds: int, fails: chan[str], done: chan[int]) {
    let ok_n = 0;
    for _i in 0..rounds {
        let o = nats.options(url);
        o.ca_path = ca;
        o.reconnect = false;
        let r = nats.connect_with(o, soon());
        guard let nc = r else let e = err_of(r) {
            chan_send(fails, "client: " + e);
            continue;
        }
        nats.close(nc);
        ok_n += 1;
    }
    chan_send(done, ok_n);
}

fn write_file(path: str, text: str) {
    let cr = fs.create(path);
    guard let fd = cr else let e = err_of(cr) { panic("create " + path + ": " + e); }
    fs.write(fd as int, to_bytes(text));
    fs.close(fd as int);
}

let dir = os.tmpdir() + "/slang_nats_tls_close_" + to_str(os.pid());
fs.mkdir(dir);
let kr = crypto.rsa_generate(2048);
guard let key = kr else let e = err_of(kr) { panic(e); }
let cr = x509.self_signed(key, x509.Request { common_name: "localhost", dns_names: ["localhost"], ip_addrs: [] }, 1);
guard let cert = cr else let e = err_of(cr) { panic(e); }
write_file(dir + "/key.pem", key);
write_file(dir + "/cert.pem", cert);
let sr: result[rawptr, str] = net.tls_server_ctx(dir + "/cert.pem", dir + "/key.pem");
guard let ctx = sr else let e = err_of(sr) { panic("server ctx: " + e); }

let tasks = 8;
let rounds = 150;
let lr = link_listen(0);
guard let ln = lr else let e = err_of(lr) { panic("listen: " + to_str(e)); }
let port = ln.port();
let fails: chan[str] = make_chan(tasks * rounds * 2 + 8);
let done: chan[int] = make_chan(tasks);
spawn server(ln, ctx, tasks * rounds, fails);
for _t in 0..tasks {
    spawn churn("tls://localhost:" + to_str(port), dir + "/cert.pem", rounds, fails, done);
}
let connected = 0;
for _t in 0..tasks {
    connected += chan_recv(done) ?? 0;
}
let failed = 0;
let first = "";
// Server tasks finish their last connection after the clients return.
time.sleep(300000000);
while true {
    let got = false;
    select {
        case let f = chan_recv(fails) {
            if failed == 0 {
                first = f ?? "";
            }
            failed += 1;
            got = true;
        }
        default { }
    }
    if !got {
        break;
    }
}
os.remove(dir + "/key.pem");
os.remove(dir + "/cert.pem");
os.remove(dir);
println("connected and closed " + to_str(connected) + " of " + to_str(tasks * rounds));
if failed > 0 {
    println("failures: " + to_str(failed) + ", first: " + first);
}
