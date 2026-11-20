// bcrypt and scrypt from many tasks at once in a program with the reactor
// linked in, so both run on the kdf threads while their tasks park. Every
// task must get the reference answer back: a job's inputs and output are
// its own.
import "crypto";
import "encoding";
import "net";

gc struct Run { lock: mutex, good: int, bad: int }

fn one(r: Run, i: int, done: chan[bool]) {
    let ok_all = true;
    let pw = "password";
    if i % 2 == 1 {
        pw = "Password";
    }
    let v = crypto.bcrypt_verify(to_bytes(pw), "$2y$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I..");
    let m = false;
    if let got = v {
        m = got;
    } else {
        ok_all = false;
    }
    if m != (i % 2 == 0) {
        ok_all = false;
    }
    let s = crypto.scrypt(b"password", b"NaCl", 1024, 8, 16, 64);
    let d = s ?? b"";
    if encoding.hex_encode(d) != "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640" {
        ok_all = false;
    }
    mutex_lock(r.lock);
    if ok_all {
        r.good += 1;
    } else {
        r.bad += 1;
    }
    mutex_unlock(r.lock);
    chan_send(done, true);
}

let r = Run { lock: make_mutex(), good: 0, bad: 0 };
let n = 24;
let done: chan[bool] = make_chan(n);
for i in 0..n {
    spawn one(r, i, done);
}
for _i in 0..n {
    let _d = chan_recv(done);
}
println("tasks " + to_str(r.good) + " good, " + to_str(r.bad) + " bad");
