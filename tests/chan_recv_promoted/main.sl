// chan_recv and join_wait allocate their opt/result box before they park
// and fill it after. A long enough wait lets minors promote the box, and
// the value stored into it then is young: an old->young edge that needs
// the write barrier. Without it the next minor freed the received value
// while the box still held it. Here each waiter parks while another task
// allocates enough to promote its box, then receives a fresh object and
// reaches a safepoint while the box is still its only holder. Run under the minor verifier
// (GC stress lists): it reported the edges as missed before the fix.

gc struct Payload {
    id: int,
    text: str,
    items: [str],
}

fn churn(rounds: int) -> int {
    let keep = 0;
    for r in 0..rounds {
        let xs: [str] = [];
        for i in 0..64 {
            push(xs, "churn " + to_str(r) + " " + to_str(i));
        }
        keep = keep + len(xs[r % 64]);
    }
    return keep;
}

fn fresh(id: int) -> Payload {
    let items: [str] = [];
    for i in 0..8 {
        push(items, "item " + to_str(id) + "." + to_str(i));
    }
    return Payload { id: id, text: "payload " + to_str(id), items: items };
}

fn check(p: Payload, id: int) -> bool {
    if p.id != id || p.text != "payload " + to_str(id) || len(p.items) != 8 {
        return false;
    }
    for i in 0..8 {
        if p.items[i] != "item " + to_str(id) + "." + to_str(i) {
            return false;
        }
    }
    return true;
}

fn receiver(ch: chan[Payload], out: chan[bool]) {
    let ok = true;
    for k in 0..4 {
        let got = chan_recv(ch);
        // A safepoint while only the box holds the value: the next minor
        // must reach it through the (now old) box.
        churn(200);
        guard let p = got else { out_send(out, false); return; }
        ok = ok && check(p, k);
    }
    out_send(out, ok);
}

fn out_send(out: chan[bool], v: bool) {
    chan_send(out, v);
}

fn slow_maker(id: int) -> Payload {
    churn(400);
    return fresh(id);
}

let ch: chan[Payload] = make_chan(1);
let out: chan[bool] = make_chan(1);
spawn receiver(ch, out);
for k in 0..4 {
    churn(400);           // the receiver is parked: its box is promoted
    chan_send(ch, fresh(k));
}
let recv_ok = chan_recv(out) ?? false;
println("chan_recv ok: " + to_str(recv_ok));

let join_ok = true;
for k in 0..4 {
    let r = join_wait(spawn slow_maker(k));
    churn(200);
    guard let p = r else let e = err_of(r) { println(e); exit(1); }
    join_ok = join_ok && check(p, k);
}
println("join_wait ok: " + to_str(join_ok));
