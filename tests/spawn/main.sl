// spawn + chan[T]: real OS-thread concurrency with failure isolation.
// chan_recv blocks until a value is ready, so every check below is a
// genuine synchronization point -- nothing here depends on timing.

fn worker(id: i32, results: chan[i32]) {
    chan_send(results, (id * 10) as i32);
}

fn sum_from(n: int, results: chan[i32]) -> int {
    let mut_sum = 0;
    for i in 0..n {
        let v = chan_recv(results);
        guard let x = v else {
            println("FAIL: unexpected none before close");
            exit(1);
        }
        mut_sum = mut_sum + x;
    }
    return mut_sum;
}

// three tasks, real concurrent execution, results rendezvous on a
// shared channel
let results: chan[i32] = make_chan(3);
spawn worker(1, results);
spawn worker(2, results);
spawn worker(3, results);
println(sum_from(3, results));

// a closed, drained channel reports 'none' instead of blocking forever
chan_close(results);
let after_close = chan_recv(results);
guard let _unused = after_close else {
    println("recv on closed+empty channel: none");
    exit(0); // guard-else must exit; this is the expected path
}
println("FAIL: expected none after close");
exit(1);
