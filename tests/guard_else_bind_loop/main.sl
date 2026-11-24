gc struct StepErr {
    idx: int,
    reason: str,
    meta: [str],
}

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn step_str(s: str) -> result[int, str] {
    if s == "STOP" {
        return err("stop");
    }
    return to_int(s);
}

fn step_gc(i: int) -> result[int, StepErr] {
    if i == 1995 {
        return err(StepErr { idx: i, reason: "halt", meta: ["h"] });
    }
    if i % 4 == 0 {
        return err(StepErr { idx: i, reason: "skip-" + to_str(i), meta: ["s", to_str(i)] });
    }
    return ok(i);
}

// for..in with continue and break inside else |e|
let vals: [int] = [];
let errs: [str] = [];
for item in ["1", "bad", "2", "STOP", "3"] {
    guard let v = step_str(item) else |e| {
        push(errs, e);
        if e == "stop" {
            break;
        }
        continue;
    }
    push(vals, v);
}
println("forin_vals=" + to_str(len(vals)) + ",errs=" + to_str(len(errs)) + ",last=" + errs[len(errs) - 1]);

// while loop with continue and break inside else |e|
let winputs = ["10", "nope", "20", "STOP", "30"];
let wi = 0;
let wsum = 0;
let werrs = 0;
while wi < len(winputs) {
    let cur = winputs[wi];
    wi += 1;
    guard let v = step_str(cur) else |e| {
        werrs += 1;
        if e == "stop" {
            break;
        }
        continue;
    }
    wsum += v;
}
println("while_sum=" + to_str(wsum) + ",errs=" + to_str(werrs));

// range for loop with gc struct errors under allocation pressure
let ok_sum = 0;
let skip_cnt = 0;
let halt_reason = "";
for i in 0..2000 {
    guard let v = step_gc(i) else |e| {
        let pad = [e.reason, to_str(i), "pad"];
        if len(e.meta) < 1 || pad[0] != e.reason {
            die("corrupt gc step err");
        }
        if e.reason == "halt" {
            halt_reason = e.reason + "@" + to_str(e.idx);
            break;
        }
        skip_cnt += 1;
        continue;
    }
    ok_sum += v;
}
println("for_ok=" + to_str(ok_sum) + ",skips=" + to_str(skip_cnt) + ",halt=" + halt_reason);
