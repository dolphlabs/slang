"""heavy/api in Python: uvloop + httptools protocol server, asyncpg, orjson.
One process per core on a shared SO_REUSEPORT socket. See bench/SPEC.md."""
import asyncio
import math
import os
import re
import socket
import sys

import asyncpg
import httptools
import orjson
import uvloop

TS = """to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""
SQL_USER = f"SELECT id, email, name, country, {TS} FROM users WHERE id = $1"
SQL_ORDERS = (f"SELECT id, sku, qty, price_cents, status, {TS} FROM orders "
              "WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2")
SQL_SUMMARY = ("SELECT status, count(*), coalesce(sum(qty * price_cents), 0) "
               "FROM orders WHERE user_id = $1 GROUP BY status")
SQL_INSERT = ("INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) "
              "VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id")

RATES = {"US": 725, "CA": 1300, "UK": 2000, "EU": 2000, "DE": 1900, "FR": 2000,
         "JP": 1000, "IN": 1800, "BR": 1700, "NG": 750, "AU": 1000}
STATUS = {200: b"200 OK", 201: b"201 Created", 400: b"400 Bad Request",
          404: b"404 Not Found", 500: b"500 Internal Server Error"}
BAD = b'{"error":"bad request"}'
NOT_FOUND = b'{"error":"not found"}'
DIGITS = re.compile(rb"^[0-9]{1,18}$")


def parse_id(b):
    if not DIGITS.match(b):
        return -1
    n = int(b)
    return n if n > 0 else -1


def quote(body):
    try:
        q = orjson.loads(body)
        rate = RATES[q["region"]]
        items = q["items"]
    except (orjson.JSONDecodeError, KeyError, TypeError):
        return None
    if not isinstance(items, list) or not items:
        return None
    sub = disc = tax = 0
    top = []  # (net, sku, pos), best first
    for pos, it in enumerate(items):
        try:
            qty = it["qty"]
            price = it["price_cents"]
            sku = it["sku"]
        except (KeyError, TypeError):
            return None
        if type(qty) is not int or type(price) is not int or qty < 1 or price < 0:
            return None
        gross = qty * price
        d = gross * 500 // 10000 if qty >= 10 else 0
        net = gross - d
        sub += gross
        disc += d
        tax += net * rate // 10000
        if len(top) < 5 or (-net, sku, pos) < (-top[-1][0], top[-1][1], top[-1][2]):
            key = (-net, sku, pos)
            at = len(top)
            while at > 0 and key < (-top[at - 1][0], top[at - 1][1], top[at - 1][2]):
                at -= 1
            top.insert(at, (net, sku, pos))
            if len(top) > 5:
                top.pop()
    return {"region": q["region"], "lines": len(items), "subtotal_cents": sub,
            "discount_cents": disc, "tax_cents": tax, "total_cents": sub - disc + tax,
            "top_skus": [t[1] for t in top]}


class Http(asyncio.Protocol):
    __slots__ = ("pool", "transport", "parser", "url", "body", "keep_alive", "queue", "busy")

    def __init__(self, pool):
        self.pool = pool
        self.transport = None
        self.parser = httptools.HttpRequestParser(self)
        self.url = b""
        self.body = []
        self.queue = []
        self.busy = False

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        try:
            self.parser.feed_data(data)
        except httptools.HttpParserError:
            self.transport.close()

    def on_url(self, url):
        self.url += url

    def on_body(self, body):
        self.body.append(body)

    def on_message_complete(self):
        req = (self.parser.get_method(), self.url, b"".join(self.body), self.parser.should_keep_alive())
        self.url = b""
        self.body = []
        # pipelined requests are answered in order
        self.queue.append(req)
        if not self.busy:
            self.busy = True
            asyncio.ensure_future(self.drain())

    async def drain(self):
        while self.queue:
            method, url, body, keep = self.queue.pop(0)
            try:
                status, payload = await self.handle(method, url, body)
            except Exception:
                status, payload = 500, b'{"error":"internal"}'
            if self.transport.is_closing():
                return
            self.transport.write(b"HTTP/1.1 " + STATUS[status] +
                                 b"\r\nContent-Type: application/json\r\nContent-Length: " +
                                 str(len(payload)).encode() + b"\r\n\r\n" + payload)
            if not keep:
                self.transport.close()
                return
        self.busy = False

    async def handle(self, method, url, body):
        qi = url.find(b"?")
        path = url if qi < 0 else url[:qi]
        if path == b"/health":
            return 200, b'{"ok":true}'
        if method == b"POST" and path == b"/api/quote":
            r = quote(body)
            return (200, orjson.dumps(r)) if r else (400, BAD)
        if method == b"POST" and path == b"/api/orders":
            return await self.create_order(body)
        if method != b"GET" or not path.startswith(b"/api/users/"):
            return 404, NOT_FOUND
        rest = path[11:]
        slash = rest.find(b"/")
        uid = parse_id(rest if slash < 0 else rest[:slash])
        tail = b"" if slash < 0 else rest[slash:]
        if tail not in (b"", b"/orders", b"/summary"):
            return 404, NOT_FOUND
        if uid < 0:
            return 400, BAD
        if tail == b"":
            r = await self.pool.fetchrow(SQL_USER, uid)
            if r is None:
                return 404, NOT_FOUND
            return 200, orjson.dumps({"id": r[0], "email": r[1], "name": r[2], "country": r[3], "created_at": r[4]})
        if tail == b"/orders":
            limit = 20
            if qi >= 0:
                for part in url[qi + 1:].split(b"&"):
                    if part.startswith(b"limit="):
                        limit = parse_id(part[6:])
                        if limit > 100:
                            limit = -1
            if limit < 0:
                return 400, BAD
            rows = await self.pool.fetch(SQL_ORDERS, uid, limit)
            return 200, orjson.dumps({"user_id": uid, "orders": [
                {"id": r[0], "sku": r[1], "qty": r[2], "price_cents": r[3], "status": r[4], "created_at": r[5]}
                for r in rows]})
        rows = await self.pool.fetch(SQL_SUMMARY, uid)
        by = {"cancelled": 0, "delivered": 0, "paid": 0, "pending": 0, "shipped": 0}
        count = total = 0
        for status, n, t in rows:
            by[status] = n
            count += n
            total += int(t)
        return 200, orjson.dumps({"user_id": uid, "order_count": count, "total_cents": total, "by_status": by})

    async def create_order(self, body):
        try:
            o = orjson.loads(body)
            uid, sku, qty, price = o["user_id"], o["sku"], o["qty"], o["price_cents"]
        except (orjson.JSONDecodeError, KeyError, TypeError):
            return 400, BAD
        if (type(uid) is not int or type(qty) is not int or type(price) is not int or type(sku) is not str
                or uid < 1 or not 1 <= qty <= 1000 or not 1 <= price <= 1000000000 or not 1 <= len(sku) <= 32):
            return 400, BAD
        new_id = await self.pool.fetchval(SQL_INSERT, uid, sku, qty, price)
        return 201, orjson.dumps({"id": new_id, "status": "pending"})


async def run(sock, pool_size):
    pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=pool_size, max_size=pool_size)
    loop = asyncio.get_running_loop()
    server = await loop.create_server(lambda: Http(pool), sock=sock)
    await server.serve_forever()


def child(port, pool_size):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", port))
    sock.listen(4096)
    uvloop.run(run(sock, pool_size))


def main():
    workers = int(os.environ.get("WORKERS") or len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count())
    port = int(os.environ.get("PORT", "8080"))
    pool_size = math.ceil(int(os.environ.get("DB_POOL_TOTAL", "64")) / workers)
    print(f"listening on {port}", flush=True)
    if workers == 1:
        child(port, pool_size)
        return
    pids = []
    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            child(port, pool_size)
            os._exit(0)
        pids.append(pid)
    os.wait()
    sys.exit(1)


if __name__ == "__main__":
    main()
