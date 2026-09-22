// crypto.rand from many tasks at once.
//
// RAND_bytes builds its DRBG lazily on first use, and two threads
// reaching that construction together deadlocked inside libcrypto's own
// rwlock -- every worker parked in CRYPTO_THREAD_write_lock, the whole
// process stopped, and nothing in slang could see why. A server giving
// each request a random id hit it at two concurrent connections.
//
// This test hangs rather than fails if that comes back, which is the
// honest shape for a deadlock.
import "crypto";

fn worker(id: int, out: chan[int]) {
    let i = 0;
    while i < 500 {
        let r = crypto.rand(16);
        guard let b = r else {
            chan_send(out, -1);
            return;
        }
        if len(b) != 16 {
            chan_send(out, -2);
            return;
        }
        i = i + 1;
    }
    chan_send(out, 0);
}

let out: chan[int] = make_chan(16);
let n = 0;
while n < 8 {
    spawn worker(n, out);
    n = n + 1;
}

let bad = 0;
let got = 0;
while got < 8 {
    let v = chan_recv(out);
    guard let code = v else {
        break;
    }
    if code != 0 {
        bad = bad + 1;
    }
    got = got + 1;
}
println("workers: " + to_str(got));
println("failures: " + to_str(bad));
