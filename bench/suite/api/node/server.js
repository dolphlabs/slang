// heavy/api in Node: node:http + postgres (porsager) + cluster, one
// process per core. See bench/SPEC.md.
import cluster from "node:cluster";
import http from "node:http";
import os from "node:os";
import postgres from "postgres";
import { quote, parseId, TS } from "./quote.js";

const WORKERS = Number(process.env.WORKERS) || os.availableParallelism();
const PORT = Number(process.env.PORT) || 8080;

if (cluster.isPrimary && WORKERS > 1) {
  for (let i = 0; i < WORKERS; i++) cluster.fork();
  cluster.on("exit", () => process.exit(1));
} else {
  const perProcess = Math.ceil((Number(process.env.DB_POOL_TOTAL) || 64) / WORKERS);
  const sql = postgres(process.env.DATABASE_URL, {
    max: perProcess,
    prepare: true,
    // int8 and numeric arrive as strings; every value here fits 2^53
    types: { bigint: postgres.BigInt },
    transform: { undefined: null },
  });

  const JSON_HEADERS = { "Content-Type": "application/json" };
  const send = (res, status, text) => {
    res.writeHead(status, { ...JSON_HEADERS, "Content-Length": Buffer.byteLength(text) });
    res.end(text);
  };
  const BAD = '{"error":"bad request"}';
  const NOT_FOUND = '{"error":"not found"}';
  const INTERNAL = '{"error":"internal"}';

  const readBody = (req) => new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });

  async function handle(req, res) {
    const url = req.url;
    const qi = url.indexOf("?");
    const path = qi < 0 ? url : url.slice(0, qi);
    if (path === "/health") return send(res, 200, '{"ok":true}');
    if (req.method === "POST" && path === "/api/orders") return createOrder(req, res);
    if (req.method === "POST" && path === "/api/quote") {
      const r = quote(await readBody(req));
      return r ? send(res, 200, JSON.stringify(r)) : send(res, 400, BAD);
    }
    if (req.method !== "GET" || !path.startsWith("/api/users/")) return send(res, 404, NOT_FOUND);
    const rest = path.slice(11);
    const slash = rest.indexOf("/");
    const id = parseId(slash < 0 ? rest : rest.slice(0, slash));
    const tail = slash < 0 ? "" : rest.slice(slash);
    if (tail !== "" && tail !== "/orders" && tail !== "/summary") return send(res, 404, NOT_FOUND);
    if (id < 0) return send(res, 400, BAD);
    if (tail === "") {
      const rows = await sql.unsafe(`SELECT id, email, name, country, ${TS} AS created_at FROM users WHERE id = $1`, [id], { prepare: true });
      if (rows.length === 0) return send(res, 404, NOT_FOUND);
      const u = rows[0];
      return send(res, 200, JSON.stringify({ id: Number(u.id), email: u.email, name: u.name, country: u.country, created_at: u.created_at }));
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
      if (limit < 0) return send(res, 400, BAD);
      const rows = await sql.unsafe(`SELECT id, sku, qty, price_cents, status, ${TS} AS created_at FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2`, [id, limit], { prepare: true });
      const orders = new Array(rows.length);
      for (let i = 0; i < rows.length; i++) {
        const r = rows[i];
        orders[i] = { id: Number(r.id), sku: r.sku, qty: r.qty, price_cents: Number(r.price_cents), status: r.status, created_at: r.created_at };
      }
      return send(res, 200, JSON.stringify({ user_id: id, orders }));
    }
    const rows = await sql.unsafe("SELECT status, count(*) AS n, coalesce(sum(qty * price_cents), 0) AS total FROM orders WHERE user_id = $1 GROUP BY status", [id], { prepare: true });
    const by = { cancelled: 0, delivered: 0, paid: 0, pending: 0, shipped: 0 };
    let count = 0, total = 0;
    for (const r of rows) {
      const n = Number(r.n);
      by[r.status] = n;
      count += n;
      total += Number(r.total);
    }
    return send(res, 200, JSON.stringify({ user_id: id, order_count: count, total_cents: total, by_status: by }));
  }

  async function createOrder(req, res) {
    let o;
    try { o = JSON.parse(await readBody(req)); } catch { return send(res, 400, BAD); }
    if (!o || !Number.isInteger(o.user_id) || typeof o.sku !== "string" || !Number.isInteger(o.qty) ||
        !Number.isInteger(o.price_cents) || o.user_id < 1 || o.qty < 1 || o.qty > 1000 ||
        o.price_cents < 1 || o.price_cents > 1000000000) return send(res, 400, BAD);
    const skuLen = [...o.sku].length;
    if (skuLen < 1 || skuLen > 32) return send(res, 400, BAD);
    const rows = await sql.unsafe("INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id", [o.user_id, o.sku, o.qty, o.price_cents], { prepare: true });
    return send(res, 201, JSON.stringify({ id: Number(rows[0].id), status: "pending" }));
  }

  const server = http.createServer({ keepAliveTimeout: 65000 }, (req, res) => {
    handle(req, res).catch(() => send(res, 500, INTERNAL));
  });
  server.listen({ port: PORT, host: "0.0.0.0", reusePort: false }, () => {
    if (cluster.isPrimary || cluster.worker.id === 1) console.log(`listening on ${PORT}`);
  });
}
