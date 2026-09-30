// --dump-mir and --dump-liveness used to reject all enum code:
// the dump entry points skipped the enum rewrite pass, so every
// Type.Variant died as "undefined variable". This program exercises
// variant references plus both from_int/from_str sentinels through
// those dumps (see expected.mir) as well as the normal run path.
enum Status {
    Pending,
    Paid,
    Shipped,
}

let s: Status = Status.Paid;
if s == Status.Paid {
    println("paid");
} else {
    println("waiting");
}

let r: result[Status, str] = Status.from_int(2);
guard let v = r else let e = err_of(r) {
    println("bad " + e);
    exit(1);
}
if v == Status.Shipped {
    println("two");
} else {
    println("wrong");
}

let r2: result[Status, str] = Status.from_str("Pending");
guard let v2 = r2 else let e2 = err_of(r2) {
    println("bad " + e2);
    exit(1);
}
if v2 == Status.Pending {
    println("named");
} else {
    println("wrong");
}
