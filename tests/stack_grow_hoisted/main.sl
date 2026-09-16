// Stack growth while an optimised caller holds a hoisted stack address.
//
// A spawned task starts on a small stack; TLS (like crypto, sql and
// compress) grows it before calling into its C library, which COPIES
// the stack and unmaps the old one. The runtime translates the pointers
// it created -- the safepoint chain, the frame-pointer chain -- but at
// -O2 clang creates more: it hoists a loop-invariant stack address (the
// safepoint struct, its roots array) into a callee-saved register
// BEFORE the call that grows, and reuses the register afterwards, now
// pointing into the unmapped old stack. Crashed 3/3 with SIGSEGV in
// sl_rt_safepoint_enter until relocation began translating every live
// word of the stack (sl_task_grower_entry).
//
// THIS PROGRAM IS KEPT VERBATIM, including the unused find_head_end,
// and that is load-bearing. Whether clang hoists is sensitive to code
// well away from the function that crashes: a tidied version of this
// same test -- a helper renamed, a short reply literal, three client
// rounds instead of one -- passed with the fix DISABLED, as did two
// compress-based shapes written to cover the bug independently. Edit
// only comments. After any change, confirm it still fails with the
// word scan in sl_task_grower_entry turned off; if a compiler upgrade
// changes register allocation, it can pass against a regression.
import "net";
import "time";

fn find_head_end(b: bytes) -> int {
    let i = 0;
    while i + 3 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn tls_read_one(ssl: rawptr) -> bool {
    let rr = net.tls_recv(ssl, 4096);
    guard let got = rr else { return false; }
    return len(got) > 0;
}

fn conn(ssl: rawptr) {
    while tls_read_one(ssl) {
        net.tls_send(ssl, b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong");
    }
    net.tls_close(ssl);
}

fn serve(lfd: i32, ctx: rawptr) {
    let hr = net.tls_accept(lfd, ctx);
    guard let ssl = hr else let e = err_of(hr) { println("accept: " + e); return; }
    spawn conn(ssl);
}

let lr = net.listen(0);
guard let lfd = lr else { exit(1); }
let pr = net.port(lfd);
guard let port = pr else { exit(1); }
let scr = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
guard let sctx = scr else { exit(1); }
spawn serve(lfd, sctx);

let ccr = net.tls_client_ctx("tests/tls/cert.pem");
guard let cctx = ccr else { exit(1); }
let dr = net.tls_dial("localhost", port, cctx);
guard let ssl = dr else let e = err_of(dr) { println("dial: " + e); exit(1); }
net.tls_send(ssl, b"GET / HTTP/1.1\r\n\r\n");
let rr = net.tls_recv(ssl, 100);
guard let got = rr else { println("client recv failed"); exit(1); }
println("client got " + to_str(len(got)) + " bytes");
