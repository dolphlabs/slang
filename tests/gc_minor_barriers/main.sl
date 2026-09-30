// Every way a young object can end up held only by an old one must go
// through the write barrier, or a minor collection frees it while it is
// live. tests/run_tests.sh runs this under SLANG_GC_VERIFY_MINOR with a
// 16KB nursery, where every minor is checked against a full mark and the
// run must report missed=0; on its own it checks the values survive.
// Each section is one path that once had no barrier:
//
// - a struct literal whose field expressions allocate: the struct used
//   to be allocated first, so a minor inside a field expression promoted
//   it before its young fields were stored;
// - a task that stores into an old object and then exits: its
//   remembered entries were dropped with the task;
// - a select that sends: its send arm skipped the barrier chan_send has;
// - a recv that parks: the result's bytes header was allocated before
//   the wait and filled after it;
// - a major collection: it kept its young survivors young while
//   discarding the remembered set that pointed at them.
import "net";
import "time";

gc struct Box {
    name: str,
    items: [str],
    n: int,
}

fn label(i: int) -> str {
    return "v" + to_str(i);
}

fn churn(n: int) -> int {
    let s = 0;
    let i = 0;
    while i < n {
        s = s + len(label(i));
        i = i + 1;
    }
    return s;
}

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// Struct literals whose fields allocate, kept across many minors.
fn literals() {
    let keep: [Box] = [];
    let i = 0;
    while i < 3000 {
        push(keep, Box { name: label(i), items: [label(i + 1), label(i + 2)],
                         n: i });
        i = i + 1;
    }
    churn(20000);
    i = 0;
    while i < len(keep) {
        let b = keep[i];
        if b.name != label(i) || b.items[1] != label(i + 2) || b.n != i {
            fail("literal " + to_str(i));
        }
        i = i + 1;
    }
    println("literals");
}

// Tasks that write into a shared old object and then finish.
fn writer(b: Box, i: int, done: chan[int]) {
    b.name = label(i);
    b.items = [label(i * 2)];
    chan_send(done, i);
}

fn exiting_tasks() {
    let boxes: [Box] = [];
    let i = 0;
    while i < 64 {
        push(boxes, Box { name: "", items: [], n: i });
        i = i + 1;
    }
    churn(20000); // the boxes are old from here on
    let done: chan[int] = make_chan(64);
    i = 0;
    while i < 64 {
        spawn writer(boxes[i], i, done);
        i = i + 1;
    }
    i = 0;
    while i < 64 {
        let _v = chan_recv(done);
        i = i + 1;
    }
    churn(20000);
    i = 0;
    while i < 64 {
        let b = boxes[i];
        if b.name != label(i) || len(b.items) != 1 || b.items[0] != label(i * 2) {
            fail("exited writer " + to_str(i));
        }
        i = i + 1;
    }
    println("exiting_tasks");
}

// select's send arm into a channel that is already old.
fn selects() {
    let c: chan[str] = make_chan(256);
    churn(20000);
    let i = 0;
    while i < 200 {
        select {
            case chan_send(c, label(i)) {}
        }
        i = i + 1;
    }
    churn(20000);
    i = 0;
    while i < 200 {
        let v = chan_recv(c);
        guard let s = v else { fail("select: closed"); }
        if s != label(i) { fail("select value " + to_str(i)); }
        i = i + 1;
    }
    println("selects");
}

// A recv that parks while another task fills the nursery.
fn sender(fd: int, n: int) {
    let i = 0;
    while i < n {
        time.sleep(1000000);
        churn(3000);
        let msg = to_bytes(label(1000 + i));
        let sr = net.send(fd, msg);
        guard let _s = sr else { return; }
        i = i + 1;
    }
}

fn recvs() {
    let lr = net.listen(0);
    guard let lfd = lr else { fail("listen"); }
    let pr = net.port(lfd);
    guard let port = pr else { fail("port"); }
    let dr = net.dial("127.0.0.1", port as int);
    guard let cfd = dr else { fail("dial"); }
    let ar = net.accept(lfd);
    guard let sfd = ar else { fail("accept"); }
    spawn sender(cfd as int, 30);
    // label(1000 + i) is always 5 bytes ("v1000".."v1029")
    let got: [bytes] = [];
    let total = 0;
    while total < 30 * 5 {
        let r = net.recv(sfd as int, 5);
        guard let b = r else { fail("recv"); }
        if len(b) == 0 { fail("early close"); }
        push(got, b);
        total = total + len(b);
    }
    churn(20000);
    let all = b"";
    for b in got {
        all = all + b;
    }
    let want = b"";
    let i = 0;
    while i < 30 {
        want = want + to_bytes(label(1000 + i));
        i = i + 1;
    }
    if all != want { fail("recv bytes"); }
    println("recvs");
}

literals();
exiting_tasks();
selects();
recvs();
println("done");
