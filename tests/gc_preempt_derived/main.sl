// A task async-preempted just after an allocation held the new object
// only by its header: sl_gc_alloc_impl is inlined and forms `h + 1`
// after its preempt bracket closes, and the conservative scan of a
// preempted task recognized payload pointers only. A minor on another
// worker freed the object, and the decoder then filled a slot another
// allocation had been given. Here 8 tasks on 4 workers decode a list of
// 400 value structs over and over and check every element. Under forced
// preemption with a 16KB nursery (tests/run_tests.sh, preemption guards)
// plain dev printed mismatches or crashed in 20 of 20 runs.
import "json";
import "strings";

struct Item {
    sku: str,
    qty: int,
}

fn body(n: int) -> str {
    let parts: [str] = [];
    let i = 0;
    while i < n {
        push(parts, "{\"sku\":\"SKU-" + to_str(i) + "\",\"qty\":" + to_str(i % 7) + "}");
        i = i + 1;
    }
    return "[" + strings.join(parts, ",") + "]";
}

fn work(text: bytes, n: int, rounds: int, out: chan[int]) {
    let bad = 0;
    let r = 0;
    while r < rounds {
        let dr: result[[Item], str] = json.decode(text);
        guard let items = dr else {
            chan_send(out, -1);
            return;
        }
        let i = 0;
        for it in items {
            if it.sku != "SKU-" + to_str(i) || it.qty != i % 7 {
                bad = bad + 1;
            }
            i = i + 1;
        }
        if i != n {
            bad = bad + 1;
        }
        r = r + 1;
    }
    chan_send(out, bad);
}

let n = 400;
let text = to_bytes(body(n));
let tasks = 8;
let out: chan[int] = make_chan(tasks);
let t = 0;
while t < tasks {
    spawn work(text, n, 1500, out);
    t = t + 1;
}
let bad = 0;
t = 0;
while t < tasks {
    let v = chan_recv(out) ?? -1;
    bad = bad + v;
    t = t + 1;
}
println("mismatches " + to_str(bad));
