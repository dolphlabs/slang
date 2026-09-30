import "time";

fn hop(id: int, done: chan[int]) {
    time.sleep(100_000_000);    // 100 ms: parks the task, not the thread
    chan_send(done, id);
}

let t0 = time.mono();
let done: chan[int] = make_chan(10_000);
for i in 0..10_000 {
    spawn hop(i, done);
}
for i in 0..10_000 {
    chan_recv(done);
}
let ms = (time.mono() - t0) / 1_000_000;
println("10000 tasks, 100 ms of sleep each: ${ms} ms");
