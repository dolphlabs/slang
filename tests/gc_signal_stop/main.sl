// A leaf loop that cannot allocate has no per-iteration poll where the
// runtime stops threads by signal (SL_ASYNC_STOP): a collection another
// task needs must interrupt it (sl_gc_stw_sync's stop signal). Here one
// task spins in such a loop for about a second while another allocates
// enough to need several collections. If the spinner could not be
// stopped, every collection would wait for its loop to end, and the
// allocator would report after it; it must report first. The spinner's
// sum checks that its reassigned list variable read the right data.

fn spin(xs: [int], ys: [int], n: int, out: chan[str]) {
    let cur = xs;
    let s = 0;
    let i = 0;
    while i < n {
        if i % 2 == 0 {
            cur = xs;
        } else {
            cur = ys;
        }
        s = s + cur[i % 4];
        i = i + 1;
    }
    chan_send(out, "spinner sum " + to_str(s));
}

fn churn(rounds: int, out: chan[str]) {
    let kept = 0;
    let r = 0;
    while r < rounds {
        let parts: [str] = [];
        let j = 0;
        while j < 1000 {
            push(parts, "item-" + to_str(j));
            j = j + 1;
        }
        kept = kept + len(parts[999]);
        r = r + 1;
    }
    chan_send(out, "allocator done " + to_str(kept));
}

let xs = [1, 2, 3, 4];
let ys = [10, 20, 30, 40];
let out: chan[str] = make_chan(2);
spawn spin(xs, ys, 1200000000, out);
spawn churn(300, out);
println(chan_recv(out) ?? "closed");
println(chan_recv(out) ?? "closed");
