// select under contention -- specifically, the enqueue window.
//
// A select polls its arms, then puts wait-list nodes on every channel,
// then parks. Between the poll and the nodes going on, it is invisible:
// a sender that lands there finds an empty wait list, wakes nobody, and
// leaves. If the select then parks without looking again, that wakeup is
// gone for good.
//
// It only turns into a HANG when the lost value was the last one --
// otherwise the next send finds the node and papers over the bug. So
// this test is built out of many small rounds that each END: two
// producers send exactly 5 items and stop, and the consumer must receive
// all 10 before the round closes. Every round is a fresh chance for the
// final item to fall in the window, and one that does never comes back.
//
// An earlier version of this test kept producers running for the whole
// program and asserted on a total. It passed with the fix REMOVED --
// steady traffic hides the bug completely. Rounds that end are the
// entire point; a version of this file where they do not is worthless.
//
// Small buffers (cap 2) are deliberate: producers fill them, park, and
// get resumed by the consumer, which maximises the interleaving.

fn burst(ch: chan[int], n: int) {
    for _i in 0..n {
        chan_send(ch, 1);
    }
}

let rounds = 0;
let items = 0;
while rounds < 300 {
    let a: chan[int] = make_chan(2);
    let b: chan[int] = make_chan(2);
    spawn burst(a, 5);
    spawn burst(b, 5);

    let got = 0;
    while got < 10 {
        select {
            case let v = chan_recv(a) {
                items = items + (v ?? 0);
                got = got + 1;
            }
            case let w = chan_recv(b) {
                items = items + (w ?? 0);
                got = got + 1;
            }
        }
    }
    rounds = rounds + 1;
}

println(rounds);
println(items);
println("done");
