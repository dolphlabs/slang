// Spawn churn: the spawner parks every batch, so it resumes on whichever
// worker picks it up, while the workers finish the batch's tasks and
// return their sl_task structs to their own per-worker cache. The
// spawner's next spawns pop a task from a cache too. Before the fix,
// clang (Darwin x86_64) resolved the cache's thread-local address once
// at the top of the spawning function and kept it across the parks, and
// GCC (linux arm64) kept the thread pointer the same way, so the spawner
// popped the first worker's cache while that worker pushed to it: two
// spawns shared one task, and the process aborted with "spawn task entry
// resumed after switching back". Every task must run exactly once.
fn work(x: int, out: chan[int]) {
    chan_send(out, x);
}

let n = 200000;
let batch = 1024;
let out: chan[int] = make_chan(batch);
let i = 0;
let sum = 0;
let got = 0;
while i < n {
    spawn work(i, out);
    i = i + 1;
    if i % batch == 0 || i == n {
        while got < i {
            let v = chan_recv(out);
            guard let x = v else { exit(1); }
            sum = sum + x;
            got = got + 1;
        }
    }
}
if sum != n * (n - 1) / 2 {
    println("FAIL: wrong sum");
    exit(1);
}
println("every task ran once");
