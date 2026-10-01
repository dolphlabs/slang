// Allocations per json.decode, for tests/run_tests.sh's budget: with
// ALLOC_BUDGET_N set it decodes the same 20-item body that many times and
// nothing else. The decode reads straight into the target type, so it
// allocates the values it returns and little more; through a parse tree
// it made a node per value, a copy of every number and a string per key.
import "json";
import "proc";

gc struct Item {
    sku: str,
    qty: int,
    price_cents: int,
}

gc struct Quote {
    region: str,
    items: [Item],
}

fn body() -> str {
    let s = "{\"region\":\"EU\",\"items\":[";
    let i = 0;
    while i < 20 {
        if i > 0 { s = s + ","; }
        s = s + "{\"sku\":\"SKU-" + to_str(10000 + i) + "\",\"qty\":" + to_str(i + 1) +
            ",\"price_cents\":" + to_str(1999 + i) + "}";
        i = i + 1;
    }
    return s + "]}";
}

let src = body();
let n = to_int(proc.getenv("ALLOC_BUDGET_N") ?? "-1") ?? -1;
if n >= 0 {
    let total = 0;
    let i = 0;
    while i < n {
        let r: result[Quote, str] = json.decode(src);
        guard let q = r else { exit(1); }
        total = total + len(q.items);
        i = i + 1;
    }
    exit(0);
}
let r: result[Quote, str] = json.decode(src);
guard let q = r else let e = err_of(r) { println("FAIL " + e); exit(1); }
let qty = 0;
for it in q.items { qty = qty + it.qty; }
println(q.region + " " + to_str(len(q.items)) + " items, qty " + to_str(qty) + ", last " + q.items[19].sku);
