// heavy/api in slang: stdlib http + pg pool + json. See bench/SPEC.md.
import "http";
import "pg";
import "json";
import "proc";
import "strings";

gc struct User {
    id: int,
    email: str,
    name: str,
    country: str,
    created_at: str,
}

gc struct Order {
    id: int,
    sku: str,
    qty: int,
    price_cents: int,
    status: str,
    created_at: str,
}

gc struct OrderList {
    user_id: int,
    orders: [Order],
}

gc struct ByStatus {
    cancelled: int,
    delivered: int,
    paid: int,
    pending: int,
    shipped: int,
}

gc struct Summary {
    user_id: int,
    order_count: int,
    total_cents: int,
    by_status: ByStatus,
}

gc struct NewOrder {
    user_id: opt[int],
    sku: opt[str],
    qty: opt[int],
    price_cents: opt[int],
}

gc struct Created {
    id: int,
    status: str,
}

gc struct QuoteItem {
    sku: str,
    qty: int,
    price_cents: int,
}

gc struct QuoteReq {
    region: str,
    items: [QuoteItem],
}

gc struct QuoteResp {
    region: str,
    lines: int,
    subtotal_cents: int,
    discount_cents: int,
    tax_cents: int,
    total_cents: int,
    top_skus: [str],
}

fn respond(status: i32, text: str, body: str) -> http.Response {
    return http.text_response(status, text, "application/json", body);
}

fn bad_request() -> http.Response {
    return respond(400, "Bad Request", "{\"error\":\"bad request\"}");
}

fn not_found() -> http.Response {
    return respond(404, "Not Found", "{\"error\":\"not found\"}");
}

fn internal(e: str) -> http.Response {
    return respond(500, "Internal Server Error", "{\"error\":\"internal\"}");
}

// A positive integer of digits only, or -1.
fn parse_id(s: str) -> int {
    let b = to_bytes(s);
    if len(b) == 0 || len(b) > 18 {
        return -1;
    }
    let n = 0;
    for c in b {
        if c < 48 || c > 57 {
            return -1;
        }
        n = n * 10 + (c - 48);
    }
    if n == 0 {
        return -1;
    }
    return n;
}

fn get_user(p: pg.Pool, id: int) -> http.Response {
    let r = pg.pool_query(p, "SELECT id, email, name, country, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM users WHERE id = $1",
                          [pg.arg_int(id)], until_of(0));
    guard let rows = r else let e = err_of(r) {
        return internal(e);
    }
    if rows.count == 0 {
        return not_found();
    }
    let u = User {
        id: pg.get_int(rows, 0, 0),
        email: pg.get_text(rows, 0, 1),
        name: pg.get_text(rows, 0, 2),
        country: pg.get_text(rows, 0, 3),
        created_at: pg.get_text(rows, 0, 4)
    };
    return respond(200, "OK", json.encode(u));
}

fn get_orders(p: pg.Pool, id: int, limit: int) -> http.Response {
    let r = pg.pool_query(p, "SELECT id, sku, qty, price_cents, status, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2",
                          [pg.arg_int(id), pg.arg_int(limit)], until_of(0));
    guard let rows = r else let e = err_of(r) {
        return internal(e);
    }
    let out = OrderList { user_id: id, orders: [] };
    let i = 0;
    while i < rows.count {
        push(out.orders, Order {
            id: pg.get_int(rows, i, 0),
            sku: pg.get_text(rows, i, 1),
            qty: pg.get_int(rows, i, 2),
            price_cents: pg.get_int(rows, i, 3),
            status: pg.get_text(rows, i, 4),
            created_at: pg.get_text(rows, i, 5)
        });
        i = i + 1;
    }
    return respond(200, "OK", json.encode(out));
}

fn get_summary(p: pg.Pool, id: int) -> http.Response {
    let r = pg.pool_query(p, "SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders WHERE user_id = $1 GROUP BY status",
                          [pg.arg_int(id)], until_of(0));
    guard let rows = r else let e = err_of(r) {
        return internal(e);
    }
    let by = ByStatus { cancelled: 0, delivered: 0, paid: 0, pending: 0, shipped: 0 };
    let s = Summary { user_id: id, order_count: 0, total_cents: 0, by_status: by };
    let i = 0;
    while i < rows.count {
        let status = pg.get_text(rows, i, 0);
        let n = pg.get_int(rows, i, 1);
        if status == "cancelled" { by.cancelled = n; }
        if status == "delivered" { by.delivered = n; }
        if status == "paid" { by.paid = n; }
        if status == "pending" { by.pending = n; }
        if status == "shipped" { by.shipped = n; }
        s.order_count = s.order_count + n;
        s.total_cents = s.total_cents + pg.get_int(rows, i, 2);
        i = i + 1;
    }
    return respond(200, "OK", json.encode(s));
}

fn create_order(p: pg.Pool, body: bytes) -> http.Response {
    let dr: result[NewOrder, str] = json.decode(body);
    guard let o = dr else {
        return bad_request();
    }
    guard let user_id = o.user_id else { return bad_request(); }
    guard let sku = o.sku else { return bad_request(); }
    guard let qty = o.qty else { return bad_request(); }
    guard let price = o.price_cents else { return bad_request(); }
    if user_id < 1 || qty < 1 || qty > 1000 || price < 1 || price > 1000000000 ||
       len(sku) < 1 || len(sku) > 32 {
        return bad_request();
    }
    let r = pg.pool_query(p, "INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id",
                          [pg.arg_int(user_id), pg.arg_text(sku), pg.arg_int(qty), pg.arg_int(price)],
                          until_of(0));
    guard let rows = r else let e = err_of(r) {
        return internal(e);
    }
    return respond(201, "Created", json.encode(Created { id: pg.get_int(rows, 0, 0), status: "pending" }));
}

fn rate_for(region: str) -> int {
    if region == "US" { return 725; }
    if region == "CA" { return 1300; }
    if region == "UK" || region == "EU" || region == "FR" { return 2000; }
    if region == "DE" { return 1900; }
    if region == "JP" || region == "AU" { return 1000; }
    if region == "IN" { return 1800; }
    if region == "BR" { return 1700; }
    if region == "NG" { return 750; }
    return -1;
}

// Byte-wise ordering of two strings: <0, 0 or >0.
fn compare(a: str, b: str) -> int {
    let x = to_bytes(a);
    let y = to_bytes(b);
    let i = 0;
    while i < len(x) && i < len(y) {
        if x[i] != y[i] {
            return x[i] - y[i];
        }
        i = i + 1;
    }
    return len(x) - len(y);
}

// Does (net a, sku a, pos a) rank ahead of b?
fn ahead(na: int, sa: str, pa: int, nb: int, sb: str, pb: int) -> bool {
    if na != nb { return na > nb; }
    if sa != sb { return compare(sa, sb) < 0; }
    return pa < pb;
}

fn quote(body: bytes) -> http.Response {
    let dr: result[QuoteReq, str] = json.decode(body);
    guard let q = dr else {
        return bad_request();
    }
    let rate = rate_for(q.region);
    if rate < 0 || len(q.items) == 0 {
        return bad_request();
    }
    let sub = 0;
    let disc = 0;
    let tax = 0;
    // the best five so far, best first
    let top_net: [int] = [];
    let top_sku: [str] = [];
    let top_pos: [int] = [];
    let pos = 0;
    for it in q.items {
        if it.qty < 1 || it.price_cents < 0 {
            return bad_request();
        }
        let gross = it.qty * it.price_cents;
        let d = 0;
        if it.qty >= 10 {
            d = gross * 500 / 10000;
        }
        let net = gross - d;
        sub = sub + gross;
        disc = disc + d;
        tax = tax + net * rate / 10000;
        let n = len(top_net);
        if n < 5 || ahead(net, it.sku, pos, top_net[n - 1], top_sku[n - 1], top_pos[n - 1]) {
            if n == 5 {
                top_net[4] = net;
                top_sku[4] = it.sku;
                top_pos[4] = pos;
            } else {
                push(top_net, net);
                push(top_sku, it.sku);
                push(top_pos, pos);
                n = n + 1;
            }
            let k = n - 1;
            while k > 0 && ahead(top_net[k], top_sku[k], top_pos[k], top_net[k - 1], top_sku[k - 1], top_pos[k - 1]) {
                let tn = top_net[k];
                let ts = top_sku[k];
                let tp = top_pos[k];
                top_net[k] = top_net[k - 1];
                top_sku[k] = top_sku[k - 1];
                top_pos[k] = top_pos[k - 1];
                top_net[k - 1] = tn;
                top_sku[k - 1] = ts;
                top_pos[k - 1] = tp;
                k = k - 1;
            }
        }
        pos = pos + 1;
    }
    let resp = QuoteResp {
        region: q.region,
        lines: len(q.items),
        subtotal_cents: sub,
        discount_cents: disc,
        tax_cents: tax,
        total_cents: sub - disc + tax,
        top_skus: top_sku
    };
    return respond(200, "OK", json.encode(resp));
}

fn route(p: pg.Pool, req: http.Request) -> http.Response {
    let target = req.path;
    let query = "";
    let qi = strings.find(target, "?");
    if qi >= 0 {
        query = strings.slice(target, qi + 1, len(target));
        target = strings.slice(target, 0, qi);
    }
    if target == "/health" {
        return respond(200, "OK", "{\"ok\":true}");
    }
    if req.method == "POST" && target == "/api/orders" {
        return create_order(p, req.body);
    }
    if req.method == "POST" && target == "/api/quote" {
        return quote(req.body);
    }
    if req.method != "GET" || !strings.has_prefix(target, "/api/users/") {
        return not_found();
    }
    let rest = strings.slice(target, 11, len(target));
    let slash = strings.find(rest, "/");
    let tail = "";
    if slash >= 0 {
        tail = strings.slice(rest, slash, len(rest));
        rest = strings.slice(rest, 0, slash);
    }
    let id = parse_id(rest);
    if tail == "" {
        if id < 0 { return bad_request(); }
        return get_user(p, id);
    }
    if tail == "/orders" {
        let limit = 20;
        for part in strings.split(query, "&") {
            if strings.has_prefix(part, "limit=") {
                limit = parse_id(strings.slice(part, 6, len(part)));
                if limit > 100 { limit = -1; }
            }
        }
        if id < 0 || limit < 0 { return bad_request(); }
        return get_orders(p, id, limit);
    }
    if tail == "/summary" {
        if id < 0 { return bad_request(); }
        return get_summary(p, id);
    }
    return not_found();
}

fn serve(p: pg.Pool, c: link) {
    let ra = arena_new(300000);
    let sa = arena_new(65536);
    // quote bodies are ~110KB; 256KB leaves room for headers and slack
    let buf = ra.wire(262144);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, route(p, got.req), &mut sa, until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) {
            return;
        }
        filled = got.filled;
    }
}

fn accept_loop(p: pg.Pool, ln: link) {
    while true {
        let ar = ln.accept(until_never());
        guard let c = ar else { continue; }
        spawn serve(p, c);
    }
}

let port = to_int(proc.getenv("PORT") ?? "8080") ?? 8080;
let pool_size = to_int(proc.getenv("DB_POOL_TOTAL") ?? "64") ?? 64;
let acceptors = to_int(proc.getenv("WORKERS") ?? "1") ?? 1;
let pr = pg.new_pool(proc.getenv("DATABASE_URL") ?? "", pool_size);
guard let pool = pr else let e = err_of(pr) {
    println("database: " + e);
    exit(1);
}
let i = 0;
while i < acceptors {
    let lr = link_listen(port, 1);
    guard let ln = lr else {
        println("listen failed on " + to_str(port));
        exit(1);
    }
    if i == acceptors - 1 {
        println("listening on " + to_str(port));
        accept_loop(pool, ln);
    } else {
        spawn accept_loop(pool, ln);
    }
    i = i + 1;
}
