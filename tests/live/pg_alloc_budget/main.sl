// GC allocations per cached pg.pool_query: one primary-key row, five text
// columns, the statement already prepared. ALLOC_BUDGET_N queries run after
// one warm-up; run.sh compares SLANG_GC_STAT at N against N = 0. Was 115 a
// query (every field of every outgoing message a fresh bytes, every reply's
// body copied out, a Describe and its RowDescription parsed every time);
// 41 with the messages written into the connection's buffer.
import "pg";
import "proc";

let n = to_int(proc.getenv("ALLOC_BUDGET_N") ?? "0") ?? 0;
let pr = pg.new_pool(proc.getenv("PG_URL") ?? "", 1);
guard let p = pr else let e = err_of(pr) {
    println("pool: " + e);
    exit(1);
}
let sql = "SELECT 7 AS id, 'a@example.com' AS email, 'A' AS name, 'NG' AS country, '2026-01-01' AS created_at WHERE $1 > 0";
let w = pg.pool_query(p, sql, [pg.arg_int(1)], until_of(0));
guard let _w = w else let e = err_of(w) {
    println("warm-up: " + e);
    exit(1);
}
let i = 0;
let seen = 0;
while i < n {
    let r = pg.pool_query(p, sql, [pg.arg_int(1 + i)], until_of(0));
    guard let rows = r else let e = err_of(r) {
        println("query: " + e);
        exit(1);
    }
    seen = seen + rows.count;
    i = i + 1;
}
if seen != n {
    println("rows " + to_str(seen) + ", expected " + to_str(n));
    exit(1);
}
exit(0);
