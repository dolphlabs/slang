import "sql";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// ---- open an in-memory database ----------------------------------
let dr = sql.open(":memory:");
guard let db = dr else let e = err_of(dr) {
    die("open: " + e);
}
println("open ok");

// ---- DDL + exec rows-affected -----------------------------------
let cr = sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL, note TEXT)");
guard let _c = cr else let e = err_of(cr) {
    die("create: " + e);
}

// ---- prepared insert, reused with reset -------------------------
let pr = sql.prepare(db, "INSERT INTO users (name, score, note) VALUES (?, ?, ?)");
guard let ins = pr else let e = err_of(pr) {
    die("prepare insert: " + e);
}

sql.bind_text(ins, 1, "ada");
sql.bind_float(ins, 2, 9.5);
sql.bind_text(ins, 3, "first");
let s1 = sql.step(ins);
guard let _d1 = s1 else let e = err_of(s1) {
    die("insert step 1: " + e);
}
println("last id " + to_str(sql.last_insert_id(db)));

sql.reset(ins);
sql.bind_text(ins, 1, "bob");
sql.bind_float(ins, 2, 7.25);
sql.bind_null(ins, 3);
let s2 = sql.step(ins);
guard let _d2 = s2 else let e = err_of(s2) {
    die("insert step 2: " + e);
}
sql.finalize(ins);

// ---- a bulk exec, rows-affected --------------------------------
let ur = sql.exec(db, "UPDATE users SET score = score + 1.0");
guard let changed = ur else let e = err_of(ur) {
    die("update: " + e);
}
println("updated " + to_str(changed) + " rows");

// ---- query + typed column access ------------------------------
let qr = sql.prepare(db, "SELECT id, name, score, note FROM users ORDER BY id");
guard let sel = qr else let e = err_of(qr) {
    die("prepare select: " + e);
}
println("cols " + to_str(sql.col_count(sel)) + " " + sql.col_name(sel, 1));

while true {
    let sr = sql.step(sel);
    guard let more = sr else let e = err_of(sr) {
        die("select step: " + e);
    }
    if !more {
        break;
    }
    let line = to_str(sql.col_int(sel, 0)) + " " + sql.col_text(sel, 1)
        + " " + to_str(sql.col_float(sel, 2));
    if sql.col_is_null(sel, 3) {
        line = line + " <null>";
    } else {
        line = line + " " + sql.col_text(sel, 3);
    }
    println(line);
}
sql.finalize(sel);

// ---- 64-bit round-trip: guards the NA_I64 arg kind ------------
// A value past 2^32 must survive bind_int -> col_int. Marshaling it
// as i32 (native.c's default for non-str/bytes/rawptr args) would
// truncate it, so this pins that the sql rows use NA_I64.
let big = 9007199254740993;
sql.exec(db, "CREATE TABLE wide (v INTEGER)");
let wp = sql.prepare(db, "INSERT INTO wide (v) VALUES (?)");
guard let wins = wp else let e = err_of(wp) {
    die("prepare wide: " + e);
}
sql.bind_int(wins, 1, big);
let ws = sql.step(wins);
guard let _w = ws else let e = err_of(ws) {
    die("wide step: " + e);
}
sql.finalize(wins);

let rp = sql.prepare(db, "SELECT v FROM wide");
guard let rsel = rp else let e = err_of(rp) {
    die("prepare wide read: " + e);
}
let rs = sql.step(rsel);
guard let _r = rs else let e = err_of(rs) {
    die("wide read step: " + e);
}
if sql.col_int(rsel, 0) != big {
    die("64-bit round-trip: got " + to_str(sql.col_int(rsel, 0)));
}
sql.finalize(rsel);
println("wide ok");

// ---- recursion bounds: keep SQLite inside the task stack -------
// sl_sql_open caps COMPOUND_SELECT and EXPR_DEPTH so the worst legal
// query fits SL_TASK_SQL_STACK_SIZE. Past the cap SQLite must report
// it through the same result[_, str] path, not run off the stack.
let deep = "SELECT 1";
for i in 0..400 {
    deep = deep + " UNION ALL SELECT 1";
}
let dp = sql.prepare(db, deep);
guard let _dd = dp else let e = err_of(dp) {
    println("compound cap: " + e);
}

let wide_expr = "SELECT 1 WHERE 1=1";
for i in 0..900 {
    wide_expr = wide_expr + " AND 1=1";
}
let ep = sql.prepare(db, wide_expr);
guard let _ee = ep else let e = err_of(ep) {
    println("expr cap: " + e);
}

// a query just inside the caps still works
let ok_compound = "SELECT 1";
for i in 0..40 {
    ok_compound = ok_compound + " UNION ALL SELECT 1";
}
let op = sql.prepare(db, ok_compound);
guard let ost = op else let e = err_of(op) {
    die("legal compound rejected: " + e);
}
sql.finalize(ost);
println("in-bounds compound ok");

// ---- error path: bad SQL stays visible through err_of ---------
let br = sql.prepare(db, "SELCT 1");
guard let _bad = br else let e = err_of(br) {
    println("syntax err: " + e);
}

let mr = sql.prepare(db, "SELECT * FROM nope");
guard let _bad2 = mr else let e = err_of(mr) {
    println("missing table: " + e);
}

let xr = sql.exec(db, "INSERT INTO users (id, name) VALUES (1, 'dup')");
guard let _x = xr else let e = err_of(xr) {
    println("exec err: " + e);
}

sql.close(db);
println("done");
