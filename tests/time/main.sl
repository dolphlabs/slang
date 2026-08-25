// Time: monotonic clock, wall clock, sleep, and duration arithmetic
// for timeouts. A duration is a fixed-width count of nanoseconds.

import "time";

let m1 = time.mono();
time.sleep(20000000); // 20 ms as a duration literal
let m2 = time.mono();

if m2 > m1 {
    println("mono advances");
} else {
    println("FAIL mono");
    exit(1);
}

// elapsed time is itself a duration; compare against a threshold
let elapsed = m2 - m1;
if elapsed >= 15000000 {
    println("sleep respected");
} else {
    println("FAIL sleep");
    exit(1);
}

// wall clock: unix nanoseconds since the epoch
let w1 = time.wall();
time.sleep(1000000);
let w2 = time.wall();
if w2 >= w1 && w1 > 1600000000000000000 {
    println("wall plausible");
} else {
    println("FAIL wall");
    exit(1);
}

// timeout arithmetic: deadline = now + budget
let deadline = time.mono() + 5000000;
if deadline > m2 {
    println("deadline math ok");
} else {
    println("FAIL deadline");
    exit(1);
}

println("time ok");
