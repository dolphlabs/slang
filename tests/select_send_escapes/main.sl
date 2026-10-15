// A struct built in a function and sent through a select's send arm is
// read by another party after that function has returned. Escape
// analysis used to keep it on the function's stack frame -- it knew
// chan_send hands a value away, not that a select send arm does -- so
// the receiver got a pointer into a dead frame: stale fields where the
// stack had not been reused yet, a crash where it had (macOS).

gc struct Msg { kind: int, text: str }

fn offer(ch: chan[Msg], n: int) -> bool {
    let m = Msg { kind: n, text: "message " + to_str(n) };
    let sent = false;
    select {
        case chan_send(ch, m) { sent = true; }
        default { }
    }
    return sent;
}

// Reuses the stack where offer's frame was.
fn scribble(depth: int) -> int {
    let a = [depth, depth + 1, depth + 2, depth + 3];
    let s = "scribble " + to_str(depth);
    if depth == 0 {
        return len(s) + a[0];
    }
    return scribble(depth - 1) + a[3];
}

let ch: chan[Msg] = make_chan(8);
let i = 0;
while i < 8 {
    offer(ch, i);
    i = i + 1;
}
println(scribble(40));
chan_close(ch);
let bad = 0;
let n = 0;
while true {
    let r = chan_recv(ch);
    guard let m = r else { break; }
    if m.kind != n || m.text != "message " + to_str(n) {
        bad = bad + 1;
    }
    n = n + 1;
}
println("received " + to_str(n) + ", wrong " + to_str(bad));
