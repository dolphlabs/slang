// heavy/api in Rust: axum on tokio, deadpool-postgres, serde_json, mimalloc.
// See bench/SPEC.md.
use axum::{
    body::Bytes,
    extract::{Path, RawQuery, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use mimalloc::MiMalloc;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

const TS: &str = r#"to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"#;

fn json(status: StatusCode, body: Vec<u8>) -> Response {
    (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
}

fn bad_request() -> Response {
    json(StatusCode::BAD_REQUEST, br#"{"error":"bad request"}"#.to_vec())
}

fn not_found() -> Response {
    json(StatusCode::NOT_FOUND, br#"{"error":"not found"}"#.to_vec())
}

fn internal() -> Response {
    json(StatusCode::INTERNAL_SERVER_ERROR, br#"{"error":"internal"}"#.to_vec())
}

fn ok<T: Serialize>(status: StatusCode, v: &T) -> Response {
    match serde_json::to_vec(v) {
        Ok(b) => json(status, b),
        Err(_) => internal(),
    }
}

/// A positive integer of digits only.
fn parse_id(s: &str) -> Option<i64> {
    if s.is_empty() || s.len() > 18 || !s.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let n: i64 = s.parse().ok()?;
    (n > 0).then_some(n)
}

#[derive(Serialize)]
struct User {
    id: i64,
    email: String,
    name: String,
    country: String,
    created_at: String,
}

#[derive(Serialize)]
struct Order {
    id: i64,
    sku: String,
    qty: i32,
    price_cents: i64,
    status: String,
    created_at: String,
}

#[derive(Serialize)]
struct OrderList {
    user_id: i64,
    orders: Vec<Order>,
}

#[derive(Serialize, Default)]
struct ByStatus {
    cancelled: i64,
    delivered: i64,
    paid: i64,
    pending: i64,
    shipped: i64,
}

#[derive(Serialize)]
struct Summary {
    user_id: i64,
    order_count: i64,
    total_cents: i64,
    by_status: ByStatus,
}

#[derive(Deserialize)]
struct NewOrder {
    user_id: i64,
    sku: String,
    qty: i64,
    price_cents: i64,
}

#[derive(Serialize)]
struct Created {
    id: i64,
    status: &'static str,
}

#[derive(Deserialize)]
struct QuoteItem {
    sku: String,
    qty: i64,
    price_cents: i64,
}

#[derive(Deserialize)]
struct QuoteReq {
    region: String,
    items: Vec<QuoteItem>,
}

#[derive(Serialize)]
struct QuoteResp<'a> {
    region: &'a str,
    lines: usize,
    subtotal_cents: i64,
    discount_cents: i64,
    tax_cents: i64,
    total_cents: i64,
    top_skus: Vec<&'a str>,
}

async fn health() -> Response {
    json(StatusCode::OK, br#"{"ok":true}"#.to_vec())
}

async fn user(State(pool): State<Pool>, Path(id): Path<String>) -> Response {
    let Some(id) = parse_id(&id) else { return bad_request() };
    let Ok(client) = pool.get().await else { return internal() };
    let sql = format!("SELECT id, email, name, country, {TS} FROM users WHERE id = $1");
    let Ok(stmt) = client.prepare_cached(&sql).await else { return internal() };
    match client.query_opt(&stmt, &[&id]).await {
        Ok(Some(r)) => ok(StatusCode::OK, &User {
            id: r.get(0),
            email: r.get(1),
            name: r.get(2),
            country: r.get(3),
            created_at: r.get(4),
        }),
        Ok(None) => not_found(),
        Err(_) => internal(),
    }
}

async fn orders(State(pool): State<Pool>, Path(id): Path<String>, RawQuery(q): RawQuery) -> Response {
    let Some(id) = parse_id(&id) else { return bad_request() };
    let mut limit = 20i64;
    for part in q.as_deref().unwrap_or("").split('&') {
        if let Some(v) = part.strip_prefix("limit=") {
            match parse_id(v) {
                Some(l) if l <= 100 => limit = l,
                _ => return bad_request(),
            }
        }
    }
    let Ok(client) = pool.get().await else { return internal() };
    let sql = format!("SELECT id, sku, qty, price_cents, status, {TS} FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2");
    let Ok(stmt) = client.prepare_cached(&sql).await else { return internal() };
    let Ok(rows) = client.query(&stmt, &[&id, &limit]).await else { return internal() };
    let orders = rows
        .iter()
        .map(|r| Order {
            id: r.get(0),
            sku: r.get(1),
            qty: r.get(2),
            price_cents: r.get(3),
            status: r.get(4),
            created_at: r.get(5),
        })
        .collect();
    ok(StatusCode::OK, &OrderList { user_id: id, orders })
}

async fn summary(State(pool): State<Pool>, Path(id): Path<String>) -> Response {
    let Some(id) = parse_id(&id) else { return bad_request() };
    let Ok(client) = pool.get().await else { return internal() };
    let Ok(stmt) = client
        .prepare_cached("SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders WHERE user_id = $1 GROUP BY status")
        .await
    else {
        return internal();
    };
    let Ok(rows) = client.query(&stmt, &[&id]).await else { return internal() };
    let mut s = Summary { user_id: id, order_count: 0, total_cents: 0, by_status: ByStatus::default() };
    for r in rows {
        let status: &str = r.get(0);
        let n: i64 = r.get(1);
        let total: Decimal = r.get(2);
        match status {
            "cancelled" => s.by_status.cancelled = n,
            "delivered" => s.by_status.delivered = n,
            "paid" => s.by_status.paid = n,
            "pending" => s.by_status.pending = n,
            "shipped" => s.by_status.shipped = n,
            _ => {}
        }
        s.order_count += n;
        s.total_cents += total.to_i64().unwrap_or(0);
    }
    ok(StatusCode::OK, &s)
}

async fn create_order(State(pool): State<Pool>, body: Bytes) -> Response {
    let Ok(o) = serde_json::from_slice::<NewOrder>(&body) else { return bad_request() };
    let sku_len = o.sku.chars().count();
    if o.user_id < 1 || !(1..=1000).contains(&o.qty) || !(1..=1_000_000_000).contains(&o.price_cents)
        || !(1..=32).contains(&sku_len)
    {
        return bad_request();
    }
    let Ok(client) = pool.get().await else { return internal() };
    let Ok(stmt) = client
        .prepare_cached("INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id")
        .await
    else {
        return internal();
    };
    let qty = o.qty as i32;
    match client.query_one(&stmt, &[&o.user_id, &o.sku, &qty, &o.price_cents]).await {
        Ok(r) => ok(StatusCode::CREATED, &Created { id: r.get(0), status: "pending" }),
        Err(_) => internal(),
    }
}

fn rate(region: &str) -> Option<i64> {
    Some(match region {
        "US" => 725,
        "CA" => 1300,
        "UK" | "EU" | "FR" => 2000,
        "DE" => 1900,
        "JP" | "AU" => 1000,
        "IN" => 1800,
        "BR" => 1700,
        "NG" => 750,
        _ => return None,
    })
}

async fn quote(body: Bytes) -> Response {
    let Ok(q) = serde_json::from_slice::<QuoteReq>(&body) else { return bad_request() };
    let Some(rate) = rate(&q.region) else { return bad_request() };
    if q.items.is_empty() {
        return bad_request();
    }
    let (mut sub, mut disc, mut tax) = (0i64, 0i64, 0i64);
    // best five so far, best first: (net, sku, position)
    let mut top: Vec<(i64, &str, usize)> = Vec::with_capacity(6);
    let ahead = |a: &(i64, &str, usize), b: &(i64, &str, usize)| {
        a.0 > b.0 || (a.0 == b.0 && (a.1 < b.1 || (a.1 == b.1 && a.2 < b.2)))
    };
    for (pos, it) in q.items.iter().enumerate() {
        if it.qty < 1 || it.price_cents < 0 {
            return bad_request();
        }
        let gross = it.qty * it.price_cents;
        let d = if it.qty >= 10 { gross * 500 / 10000 } else { 0 };
        let net = gross - d;
        sub += gross;
        disc += d;
        tax += net * rate / 10000;
        let cand = (net, it.sku.as_str(), pos);
        if top.len() < 5 || ahead(&cand, &top[top.len() - 1]) {
            if top.len() == 5 {
                top.pop();
            }
            let at = top.iter().position(|t| ahead(&cand, t)).unwrap_or(top.len());
            top.insert(at, cand);
        }
    }
    ok(StatusCode::OK, &QuoteResp {
        region: &q.region,
        lines: q.items.len(),
        subtotal_cents: sub,
        discount_cents: disc,
        tax_cents: tax,
        total_cents: sub - disc + tax,
        top_skus: top.iter().map(|t| t.1).collect(),
    })
}

fn env_usize(name: &str, def: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).filter(|&v| v > 0).unwrap_or(def)
}

fn main() {
    let workers = env_usize("WORKERS", std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1));
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .enable_all()
        .build()
        .expect("runtime")
        .block_on(serve());
}

async fn serve() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    let pg_config: tokio_postgres::Config = url.parse().expect("DATABASE_URL");
    let mgr = Manager::from_config(pg_config, tokio_postgres::NoTls, ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });
    let pool = Pool::builder(mgr).max_size(env_usize("DB_POOL_TOTAL", 64)).build().expect("pool");

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/users/{id}", get(user))
        .route("/api/users/{id}/orders", get(orders))
        .route("/api/users/{id}/summary", get(summary))
        .route("/api/orders", post(create_order))
        .route("/api/quote", post(quote))
        .fallback(|| async { not_found() })
        .with_state(pool);

    let port = env_usize("PORT", 8080);
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port as u16)).await.expect("bind");
    eprintln!("listening on {port}");
    axum::serve(listener, app).await.expect("serve");
}
