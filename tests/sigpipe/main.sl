// Writing to a peer that hung up must be an ERROR, not a funeral.
//
// SIGPIPE's default disposition kills the process. For a server that is
// both catastrophic and completely routine: a client closing a browser
// tab mid-response would take down every other connection in the
// process with it, because one signal ends every green task at once.
//
// Nothing in the runtime touched SIGPIPE, so this killed any slang
// server the first time a client hung up early. The suite never caught
// it because every existing test has its peers close politely, with a
// read returning 0 before anything is written back.
//
// The fix is one line in sl_pool_start (signal(SIGPIPE, SIG_IGN)); this
// test is what keeps it there. If it regresses, this exits 141 rather
// than failing an assertion, which is exactly the symptom to recognise.

import "net";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

// Connects and hangs up immediately, the way a client that navigates
// away does.
fn rude_client(port: int, done: chan[bool]) {
    let dr = net.dial("127.0.0.1", port);
    guard let fd = dr else {
        chan_send(done, false);
        return;
    }
    net.close(fd);
    chan_send(done, true);
}

// Proves the process survived: a task that is still running after the
// writes above would have died with everything else.
fn still_alive(out: chan[str]) {
    time.sleep(ms(50));
    chan_send(out, "other tasks still running");
}

fn run() {
    let lr = net.listen(0);
    guard let lfd = lr else let e = err_of(lr) {
        println("FAIL listen: " + e);
        exit(1);
    }
    let pr = net.port(lfd);
    guard let port = pr else { println("FAIL port"); exit(1); }

    let done: chan[bool] = make_chan(2);
    let out: chan[str] = make_chan(2);
    spawn rude_client(port, done);
    spawn still_alive(out);

    let ar = net.accept(lfd);
    guard let cfd = ar else { println("FAIL accept"); exit(1); }

    let dv = chan_recv(done);
    guard let dialed = dv else { println("FAIL done closed"); exit(1); }
    if !dialed { println("FAIL client could not dial"); exit(1); }
    time.sleep(ms(200));      // let the peer's FIN/RST land

    // Enough writes to get past the socket buffer and reach a real
    // write on a dead connection. One send often just buffers.
    let failed = false;
    let i = 0;
    while i < 200 {
        let sr = net.send(cfd, b"hello there, are you still listening?");
        guard let _n = sr else {
            failed = true;
            i = 200;
        }
        i = i + 1;
    }
    if !failed {
        println("FAIL every write to a dead peer reported success");
        exit(1);
    }
    println("write to a hung-up peer returned an error");

    let ov = chan_recv(out);
    guard let msg = ov else { println("FAIL out closed"); exit(1); }
    println(msg);

    net.close(cfd);
    net.close(lfd);
}

run();
