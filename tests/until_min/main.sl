// until_min: the earlier of two deadlines, with never later than any
// instant, and arguments that are calls evaluated once each.
import "time";

gc struct Count { n: int }

fn soon(c: Count, ns: int) -> until {
    c.n = c.n + 1;
    return until_of(time.mono() + ns);
}

let past = until_of(1);
let far = until_of(time.mono() + 60000000000);
println(until_hit(until_min(past, far)));
println(until_hit(until_min(far, past)));
println(until_hit(until_min(until_never(), until_never())));
println(until_hit(until_min(until_never(), past)));
println(until_hit(until_min(past, until_never())));
println(until_hit(until_min(until_never(), far)));
println(until_hit(until_min(far, until_never())));

// 20ms against 60s: the 20ms one ends first, and both calls ran once.
let calls = Count { n: 0 };
let short = until_min(soon(calls, 20000000), soon(calls, 60000000000));
println(calls.n);
println(until_hit(short));
time.sleep(30000000);
println(until_hit(short));
