// Decode probe for fix-gc.md: TASKS tasks each decode the quote body ITERS
// times and, like the api handler, walk the items while the result is live
// (USE=1). USE=0 drops the result straight away, which is the case #290
// measured: no collection ever finds the tree live, so nothing is promoted.
import "json";
import "fs";
import "proc";
import "time";

gc struct QuoteItem { sku: str, qty: int, price_cents: int }
gc struct QuoteReq { region: str, items: [QuoteItem] }

fn work(body: bytes, iters: int, use: bool) -> int {
    let sum = 0;
    let i = 0;
    while i < iters {
        let dr: result[QuoteReq, str] = json.decode(body);
        guard let q = dr else { return -1; }
        if use {
            for it in q.items {
                sum = sum + it.qty * it.price_cents;
            }
        } else {
            sum = sum + len(q.items);
        }
        i = i + 1;
    }
    return sum;
}

let path = proc.getenv("QUOTE") ?? "";
let fr = fs.open(path);
guard let fd = fr else {
    println("open failed: " + path);
    exit(1);
}
let br = fs.read(fd, 1000000);
guard let body = br else {
    println("read failed: " + path);
    exit(1);
}
let tasks = to_int(proc.getenv("TASKS") ?? "1") ?? 1;
let iters = to_int(proc.getenv("ITERS") ?? "200") ?? 200;
let use_items = (proc.getenv("USE") ?? "1") == "1";
let t0 = time.mono();
let hs: [join[int]] = [];
let k = 0;
while k < tasks {
    push(hs, spawn work(body, iters, use_items));
    k = k + 1;
}
for h in hs {
    let r = join_wait(h);
    guard let v = r else {
        println("task failed");
        exit(1);
    }
    if v < 0 {
        println("decode failed");
        exit(1);
    }
}
let ms = (time.mono() - t0) / 1000000;
println("tasks=" + to_str(tasks) + " decodes=" + to_str(tasks * iters) +
        " wall_ms=" + to_str(ms));
