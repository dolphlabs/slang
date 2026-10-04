// Request-shaped garbage must die young. Each round decodes a 2,000-item
// body and walks the result while it is live, the way an api handler
// does. Objects used to be promoted after surviving one minor, so a minor
// landing mid-walk promoted the whole tree and it died old, for majors to
// sweep: about 30% of every allocation. Promotion now takes two
// survivals (fix-gc.md 1.2). tests/run_tests.sh pins the promoted count
// under SLANG_GC_STAT ("promotion budgets").
import "json";
import "strings";

gc struct Item {
    sku: str,
    qty: int,
    price_cents: int,
}

gc struct Req {
    region: str,
    items: [Item],
}

fn make_body(n: int) -> bytes {
    let parts: [str] = [];
    let i = 0;
    while i < n {
        push(parts, "{\"sku\":\"SKU-" + to_str(10000 + i) + "\",\"qty\":" + to_str(i % 13 + 1) +
             ",\"price_cents\":" + to_str(100 + i % 997) + "}");
        i = i + 1;
    }
    return to_bytes("{\"region\":\"EU\",\"items\":[" + strings.join(parts, ",") + "]}");
}

let body = make_body(2000);
let total = 0;
let r = 0;
while r < 150 {
    let dr: result[Req, str] = json.decode(body);
    guard let q = dr else {
        println("decode failed");
        exit(1);
    }
    for it in q.items {
        total = total + it.qty * it.price_cents;
    }
    r = r + 1;
}
println("total: " + to_str(total));
