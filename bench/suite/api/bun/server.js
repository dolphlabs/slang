// heavy/api in Bun: Bun.serve + built-in Bun.SQL, one process per core
// sharing the port (reusePort). See bench/SPEC.md.
import { SQL } from "bun";
import { quote, parseId, TS } from "./quote.js";
import os from "node:os";

const WORKERS = Number(process.env.WORKERS) || os.availableParallelism();
const PORT = Number(process.env.PORT) || 8080;

if (!process.env.BENCH_CHILD && WORKERS > 1) {
  const children = [];
  for (let i = 0; i < WORKERS; i++) {
    children.push(Bun.spawn([process.execPath, import.meta.path], {
      env: { ...process.env, BENCH_CHILD: String(i) },
      stdout: "inherit", stderr: "inherit",
    }));
  }
  const stop = () => { for (const c of children) c.kill(); process.exit(0); };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  await Promise.race(children.map((c) => c.exited));
  process.exit(1);
}

const perProcess = Math.ceil((Number(process.env.DB_POOL_TOTAL) || 64) / WORKERS);
const sql = new SQL({ url: process.env.DATABASE_URL, max: perProcess, bigint: false });

const HEADERS = { "Content-Type": "application/json" };
const json = (status, text) => new Response(text, { status, headers: HEADERS });
const BAD = '{"error":"bad request"}';
const NOT_FOUND = '{"error":"not found"}';

const SQL_USER = `SELECT id, email, name, country, ${TS} AS created_at FROM users WHERE id = $1`;
const SQL_ORDERS = `SELECT id, sku, qty, price_cents, status, ${TS} AS created_at FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2`;
const SQL_SUMMARY = "SELECT status, count(*) AS n, coalesce(sum(qty * price_cents), 0) AS total FROM orders WHERE user_id = $1 GROUP BY status";
const SQL_INSERT = "INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id";

async function handle(req) {
  const url = req.url;
  const start = url.indexOf("/", 8);
  const qi = url.indexOf("?", start);
  const path = qi < 0 ? url.slice(start) : url.slice(start, qi);
  if (path === "/health") return json(200, '{"ok":true}');
  if (req.method === "POST" && path === "/api/quote") {
    const r = quote(await req.text());
    return r ? json(200, JSON.stringify(r)) : json(400, BAD);
  }
  if (req.method === "POST" && path === "/api/orders") {
    let o;
    try { o = JSON.parse(await req.text()); } catch { return json(400, BAD); }
    if (!o || !Number.isInteger(o.user_id) || typeof o.sku !== "string" || !Number.isInteger(o.qty) ||
        !Number.isInteger(o.price_cents) || o.user_id < 1 || o.qty < 1 || o.qty > 1000 ||
        o.price_cents < 1 || o.price_cents > 1000000000) return json(400, BAD);
    const skuLen = [...o.sku].length;
    if (skuLen < 1 || skuLen > 32) return json(400, BAD);
    const rows = await sql.unsafe(SQL_INSERT, [o.user_id, o.sku, o.qty, o.price_cents]);
    return json(201, JSON.stringify({ id: Number(rows[0].id), status: "pending" }));
  }
  if (req.method !== "GET" || !path.startsWith("/api/users/")) return json(404, NOT_FOUND);
  const rest = path.slice(11);
  const slash = rest.indexOf("/");
  const id = parseId(slash < 0 ? rest : rest.slice(0, slash));
  const tail = slash < 0 ? "" : rest.slice(slash);
  if (tail !== "" && tail !== "/orders" && tail !== "/summary") return json(404, NOT_FOUND);
  if (id < 0) return json(400, BAD);
  if (tail === "") {
    const rows = await sql.unsafe(SQL_USER, [id]);
    if (rows.length === 0) return json(404, NOT_FOUND);
    const u = rows[0];
    return json(200, JSON.stringify({ id: Number(u.id), email: u.email, name: u.name, country: u.country, created_at: u.created_at }));
  }
  if (tail === "/orders") {
    let limit = 20;
    if (qi >= 0) {
      for (const part of url.slice(qi + 1).split("&")) {
        if (part.startsWith("limit=")) {
          limit = parseId(part.slice(6));
          if (limit > 100) limit = -1;
        }
      }
    }
    if (limit < 0) return json(400, BAD);
    const rows = await sql.unsafe(SQL_ORDERS, [id, limit]);
    const orders = new Array(rows.length);
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      orders[i] = { id: Number(r.id), sku: r.sku, qty: r.qty, price_cents: Number(r.price_cents), status: r.status, created_at: r.created_at };
    }
    return json(200, JSON.stringify({ user_id: id, orders }));
  }
  const rows = await sql.unsafe(SQL_SUMMARY, [id]);
  const by = { cancelled: 0, delivered: 0, paid: 0, pending: 0, shipped: 0 };
  let count = 0, total = 0;
  for (const r of rows) {
    const n = Number(r.n);
    by[r.status] = n;
    count += n;
    total += Number(r.total);
  }
  return json(200, JSON.stringify({ user_id: id, order_count: count, total_cents: total, by_status: by }));
}

Bun.serve({
  port: PORT,
  reusePort: true,
  maxRequestBodySize: 8 * 1024 * 1024,
  fetch: (req) => handle(req).catch(() => json(500, '{"error":"internal"}')),
});
if (!process.env.BENCH_CHILD || process.env.BENCH_CHILD === "0") console.log(`listening on ${PORT}`);
