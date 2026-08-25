// A runtime error inside a spawned task terminates that task only --
// not the process, and not any other concurrently running task. The
// panic message goes to stderr, so stdout (checked against
// expected.txt) stays deterministic; results are summed (not
// printed as they arrive) so real thread-scheduling order can't
// affect the expected output either.

fn bad_worker(done: chan[bool]) {
    let xs = [1, 2, 3];
    println(xs[99]); // out of bounds: panics this task only
    chan_send(done, true); // never reached
}

fn good_worker(id: i32, results: chan[i32]) {
    chan_send(results, (id * 10) as i32);
}

let results: chan[i32] = make_chan(3);
let done: chan[bool] = make_chan(1); // unused by bad_worker; never filled

spawn bad_worker(done);
spawn good_worker(1, results);
spawn good_worker(2, results);
spawn good_worker(3, results);

let mut_sum = 0;
for i in 0..3 {
    let v = chan_recv(results);
    guard let x = v else {
        println("FAIL: unexpected none");
        exit(1);
    }
    mut_sum = mut_sum + x;
}
println(mut_sum);
println("process survived a spawned task's panic");
