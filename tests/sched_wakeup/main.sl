fn worker(id: int, n: int, done: chan[bool]) {
    let i = 0;
    while i < n {
        i = i + 1;
    }
    chan_send(done, true);
}

fn pinger(c: chan[int], n: int) {
    let i = 0;
    while i < n {
        chan_send(c, i);
        i = i + 1;
    }
}

let done: chan[bool] = make_chan(64);
let c: chan[int] = make_chan(64);
let workers = 16;
let per = 50;
let i = 0;
while i < workers {
    spawn worker(i, 200, done);
    i = i + 1;
}
spawn pinger(c, workers * per);
let got = 0;
let w = 0;
while w < workers {
    let v = chan_recv(done);
    guard let _t = v else {
        println("FAIL done closed");
        exit(1);
    }
    w = w + 1;
}
while got < workers * per {
    let v = chan_recv(c);
    guard let _x = v else {
        println("FAIL chan closed");
        exit(1);
    }
    got = got + 1;
}
println("sched wakeup ok");