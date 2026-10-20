// Argon2id in a program with the reactor linked in derives on kdf threads
// while the calling task parks, so a burst of hashes neither pins the
// pool's workers nor holds up a collection. On two workers, 64 hashes
// used to leave a ticker task a handful of turns between them; now it
// keeps its pace throughout. Pace, not a count: a fast machine finishes
// the hashes in a few hundred milliseconds, so the ticker is held to at
// least one turn per 10 ms of the run (inline it managed one per 40-300 ms).
// run_tests.sh runs this with SLANG_WORKERS=2.
import "crypto";
import "encoding";
import "net";
import "time";

gc struct Run {
    lock: mutex,
    done: int,
    ticks: int,
    bad: int,
}

fn hashes() -> int {
    return 64;
}

fn want() -> str {
    return "65eeb6d97a29f68d1c93c9e4e20049cacb7a5df8985b1db60c5772d48cc65ac6";
}

fn hash_one(r: Run) {
    let t = crypto.argon2id_raw(b"password", b"1234567890abcdef", 2, 19456, 1, 32);
    let good = false;
    if let tag = t {
        good = encoding.hex_encode(tag) == want();
    }
    let junk: [str] = [];
    for i in 0..200 {
        push(junk, "garbage " + to_str(i));
    }
    mutex_lock(r.lock);
    r.done += 1;
    if !good {
        r.bad += 1;
    }
    mutex_unlock(r.lock);
}

fn ticker(r: Run) -> int {
    while true {
        mutex_lock(r.lock);
        let finished = r.done == hashes();
        if !finished {
            r.ticks += 1;
        }
        mutex_unlock(r.lock);
        if finished {
            return 0;
        }
        time.sleep(1000000);
    }
    return 0;
}

let probe = crypto.argon2id_raw(b"password", b"1234567890abcdef", 2, 19456, 1, 32);
guard let _p = probe else let e = err_of(probe) {
    if e == "Argon2id requires OpenSSL 3.2 or newer with Argon2 support" {
        println("kdf offload ok");
        exit(0);
    }
    println("FAIL probe: " + e);
    exit(1);
}
let r = Run { lock: make_mutex(), done: 0, ticks: 0, bad: 0 };
let t0 = time.mono();
let t = spawn ticker(r);
for i in 0..hashes() {
    spawn hash_one(r);
}
let _w = join_wait(t);
let elapsed_ms = ((time.mono() - t0) as int) / 1000000;
if r.bad > 0 {
    println("FAIL " + to_str(r.bad) + " hashes wrong");
    exit(1);
}
if r.ticks * 10 < elapsed_ms {
    println("FAIL ticker starved: " + to_str(r.ticks) + " ticks in " + to_str(elapsed_ms) + " ms of " + to_str(hashes()) + " hashes");
    exit(1);
}
println("kdf offload ok");
