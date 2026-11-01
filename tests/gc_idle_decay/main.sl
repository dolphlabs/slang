// The RSS story of a bursty heap: the sweep gives back what a burst
// built. Two mechanisms, checked at exit through SLANG_GC_STAT (see
// run_tests.sh's "idle decay rss" block):
//
// 1. Spans. Objects of 256KB total and up take their own mmap and give
//    it back whole at the sweep death. A list pushed past 131072 ints
//    rebuilds 1MB-class backing buffers as it doubles; the replaced
//    buffers die young, big-string churn dies young too. `spans > 0`
//    and `span_frees > 0` on the stat line say both directions happen.
// 2. Decay. The nursery's adapted trigger used to sit at its burst
//    high water forever; the idle decay walks it back during an
//    allocation-free stretch. The workload bursts enough live-young
//    per minor for the trigger's hysteresis to chase it up, sleeps
//    150ms -- three decay windows' worth -- and exits: the
//    `nursery_threshold=` at exit reads under the 16MB high water this
//    workload reaches with the trigger grown (and far under if the
//    heap never lifted it past the decay floor).
//
// Old runtime, both checks fail: no spans/decays fields, and the
// trigger stays at its 16MB high water after the sleep.

import "strings";
import "time";

let held: [int] = [];

let r = 0;
let churn = 0;
while r < 12 {
    let burst: [int] = [];
    let i = 0;
    while i < 131072 {
        push(burst, i * 257);
        i += 1;
    }
    // one live round in four: live-young for the adapted trigger to
    // chase, dropped after two minors so nothing survives to majors
    if r % 4 == 0 {
        held = burst;
    }
    // 800KB string churn: born big, dies young, spans both ways
    let s = strings.repeat("q", 400000) + to_str(r);
    churn = churn + len(s);
    r += 1;
}
held = [];

time.sleep(150000000);

println("churn " + to_str(churn));
