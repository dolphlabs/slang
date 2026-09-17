import "json";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

enum Status {
    Pending,
    Paid,
    Shipped,
    Delivered,
    Cancelled,
}

enum PgType {
    Bool = 16,
    Bytea = 17,
    Int8 = 20,
    Text = 25,
}

// ---- ordinals: auto-increment and explicit-with-gaps ----

if Status.Pending as i32 != 0 { die("Status.Pending ordinal"); }
if Status.Paid as i32 != 1 { die("Status.Paid ordinal"); }
if Status.Cancelled as i32 != 4 { die("Status.Cancelled ordinal"); }
if PgType.Bool as i32 != 16 { die("PgType.Bool ordinal"); }
if PgType.Bytea as i32 != 17 { die("PgType.Bytea ordinal"); }
if PgType.Text as i32 != 25 { die("PgType.Text ordinal"); }
println("ordinals ok");

// ---- == / != ----

let s = Status.Paid;
if !(s == Status.Paid) { die("== same variant"); }
if s == Status.Pending { die("== different variant"); }
if !(s != Status.Pending) { die("!= different variant"); }
if s != Status.Paid { die("!= same variant"); }
println("comparison ok");

// ---- to_str / println / + ----

if to_str(Status.Delivered) != "Delivered" { die("to_str"); }
if Status.Shipped + "!" != "Shipped!" { die("+ enum onto string"); }
if "status: " + Status.Cancelled != "status: Cancelled" { die("+ string onto enum"); }
println(Status.Paid);
println("comparison and to_str ok");

// ---- from_int / from_str ----

let r1: result[Status, str] = Status.from_int(2);
guard let s1 = r1 else let e1 = err_of(r1) { die("from_int hit: " + e1); }
if s1 != Status.Shipped { die("from_int wrong variant"); }

let r2: result[Status, str] = Status.from_int(99);
guard let s2 = r2 else let e2 = err_of(r2) {
    if e2 != "not a valid Status variant" { die("from_int miss message: " + e2); }
}

let r3: result[Status, str] = Status.from_str("Cancelled");
guard let s3 = r3 else let e3 = err_of(r3) { die("from_str hit: " + e3); }
if s3 != Status.Cancelled { die("from_str wrong variant"); }

let r4: result[Status, str] = Status.from_str("nope");
guard let s4 = r4 else let e4 = err_of(r4) {
    if e4 != "not a valid Status variant" { die("from_str miss message: " + e4); }
}
println("from_int/from_str ok");

// ---- struct field ----

gc struct Order {
    id: int,
    status: Status,
}

let o = Order{ id: 7, status: Status.Shipped };
if o.status != Status.Shipped { die("struct field read"); }
o.status = Status.Delivered;
if o.status != Status.Delivered { die("struct field write"); }
println("struct field ok");

// ---- map key ----

let counts: map[Status]int = {};
counts[Status.Paid] = 3;
counts[Status.Shipped] = 7;
if counts[Status.Paid] != 3 { die("map read Paid"); }
if counts[Status.Shipped] != 7 { die("map read Shipped"); }
if has(counts, Status.Pending) { die("map has() false positive"); }
if !has(counts, Status.Paid) { die("map has() false negative"); }
println("map key ok");

// ---- json ----

let s5: str = json.encode(o);
if s5 != "{\"id\":7,\"status\":\"Delivered\"}" { die("json encode: " + s5); }

let r5: result[Order, str] = json.decode(s5);
guard let o2 = r5 else let e5 = err_of(r5) { die("json decode: " + e5); }
if o2.id != 7 { die("json decode id"); }
if o2.status != Status.Delivered { die("json decode status"); }

let r6: result[Order, str] = json.decode("{\"id\":1,\"status\":\"NotReal\"}");
guard let o3 = r6 else let e6 = err_of(r6) {
    if e6 != "field 'status': not a valid Status: NotReal" {
        die("json decode bad variant message: " + e6);
    }
}
println("json ok");
