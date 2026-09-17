#!/usr/bin/env python3
"""Conformance check for heavy/api (bench/SPEC.md). Standard library only.

    DATABASE_URL=postgres://... python3 conformance.py http://127.0.0.1:8080 <quote_dir>

Expected values come from the database itself, through psql, using the
SPEC's own SQL -- so the check does not re-implement the data, and cannot
drift from it. Exits 0 when every check passes; otherwise prints each
failure and exits 1. A server that fails is not measured.
"""
import http.client
import json
import os
import subprocess
import sys
import urllib.parse

TS = """to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""
STATUSES = ["cancelled", "delivered", "paid", "pending", "shipped"]
RATES = {"US": 725, "CA": 1300, "UK": 2000, "EU": 2000, "DE": 1900, "FR": 2000,
         "JP": 1000, "IN": 1800, "BR": 1700, "NG": 750, "AU": 1000}

failures = []


def fail(what, detail):
    failures.append(f"{what}: {detail}")


def psql(sql, *args):
    """Rows as lists of strings. Parameters are substituted as literals."""
    for a in args:
        sql = sql.replace("%s", str(int(a)), 1)
    # PSQL_CMD overrides the client, e.g. "docker exec -i pg psql -U bench -d bench"
    cmd = os.environ.get("PSQL_CMD", "").split() or ["psql", os.environ["DATABASE_URL"]]
    out = subprocess.run(cmd + ["-X", "-At", "-F", "\t", "-c", sql],
                         check=True, capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]


class Client:
    def __init__(self, base):
        u = urllib.parse.urlsplit(base)
        self.host, self.port = u.hostname, u.port
        self.conn = None

    def request(self, method, path, body=None, headers=None, fresh=False):
        if fresh or self.conn is None:
            if self.conn:
                self.conn.close()
            self.conn = http.client.HTTPConnection(self.host, self.port, timeout=30)
        h = {"Content-Type": "application/json"} if body is not None else {}
        h.update(headers or {})
        data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
        try:
            self.conn.request(method, path, body=data, headers=h)
            r = self.conn.getresponse()
            raw = r.read()
        except (http.client.HTTPException, OSError) as e:
            self.conn = None
            return None, None, None, str(e)
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), raw, None


def expect_json(c, what, method, path, status, expected=None, body=None, check=None):
    st, headers, raw, err = c.request(method, path, body)
    if err:
        fail(what, f"request failed: {err}")
        return None
    if st != status:
        fail(what, f"status {st}, want {status}; body {raw[:200]!r}")
        return None
    ctype = headers.get("content-type", "")
    if not ctype.startswith("application/json"):
        fail(what, f"content-type {ctype!r}")
    if "content-length" not in headers:
        fail(what, "no Content-Length")
    elif int(headers["content-length"]) != len(raw):
        fail(what, f"Content-Length {headers['content-length']} but body is {len(raw)} bytes")
    try:
        got = json.loads(raw)
    except ValueError:
        fail(what, f"body is not JSON: {raw[:200]!r}")
        return None
    if expected is not None and got != expected:
        fail(what, f"got {json.dumps(got)[:400]}\n      want {json.dumps(expected)[:400]}")
    if check:
        check(got)
    return got


def expected_user(uid):
    rows = psql(f"SELECT id, email, name, country, {TS} FROM users WHERE id = %s", uid)
    if not rows:
        return None
    i, e, n, c, t = rows[0]
    return {"id": int(i), "email": e, "name": n, "country": c, "created_at": t}


def expected_orders(uid, limit):
    rows = psql(f"SELECT id, sku, qty, price_cents, status, {TS} FROM orders "
                "WHERE user_id = %s ORDER BY created_at DESC, id DESC LIMIT %s", uid, limit)
    return {"user_id": uid, "orders": [
        {"id": int(i), "sku": s, "qty": int(q), "price_cents": int(p), "status": st, "created_at": t}
        for i, s, q, p, st, t in rows]}


def expected_summary(uid):
    rows = psql("SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders "
                "WHERE user_id = %s GROUP BY status", uid)
    by = {s: 0 for s in STATUSES}
    total = count = 0
    for s, n, t in rows:
        by[s] = int(n)
        count += int(n)
        total += int(t)
    return {"user_id": uid, "order_count": count, "total_cents": total, "by_status": by}


def expected_quote(body):
    rate = RATES[body["region"]]
    sub = disc = tax = 0
    nets = []
    for pos, it in enumerate(body["items"]):
        gross = it["qty"] * it["price_cents"]
        d = gross * 500 // 10000 if it["qty"] >= 10 else 0
        net = gross - d
        t = net * rate // 10000
        sub += gross
        disc += d
        tax += t
        nets.append((-net, it["sku"], pos))
    nets.sort()
    return {"region": body["region"], "lines": len(body["items"]), "subtotal_cents": sub,
            "discount_cents": disc, "tax_cents": tax, "total_cents": (sub - disc) + tax,
            "top_skus": [sku for _, sku, _ in nets[:5]]}


def main(base, quote_dir):
    c = Client(base)
    users = int(psql("SELECT v FROM bench_meta WHERE k = 'users'")[0][0])
    seeded_orders = int(psql("SELECT v FROM bench_meta WHERE k = 'orders'")[0][0])

    expect_json(c, "health", "GET", "/health", 200, {"ok": True})
    expect_json(c, "unknown path", "GET", "/nope", 404, {"error": "not found"})

    for uid in (1, 2, users // 2, users):
        expect_json(c, f"user {uid}", "GET", f"/api/users/{uid}", 200, expected_user(uid))
    expect_json(c, "user missing", "GET", f"/api/users/{users + 1}", 404, {"error": "not found"})
    for bad in ("0", "-1", "abc", "1x", "99999999999999999999999"):
        expect_json(c, f"user id {bad!r}", "GET", f"/api/users/{bad}", 400, {"error": "bad request"})

    for uid, limit in ((1, None), (7, 1), (users // 3, 50), (users, 100)):
        q = "" if limit is None else f"?limit={limit}"
        expect_json(c, f"orders {uid}{q}", "GET", f"/api/users/{uid}/orders{q}", 200,
                    expected_orders(uid, limit or 20))
    expect_json(c, "orders unknown user", "GET", f"/api/users/{users + 5}/orders", 200,
                {"user_id": users + 5, "orders": []})
    for bad in ("0", "101", "abc", ""):
        expect_json(c, f"orders limit {bad!r}", "GET", f"/api/users/1/orders?limit={bad}", 400,
                    {"error": "bad request"})

    for uid in (1, 11, users // 2, users):
        expect_json(c, f"summary {uid}", "GET", f"/api/users/{uid}/summary", 200, expected_summary(uid))
    expect_json(c, "summary unknown user", "GET", f"/api/users/{users + 9}/summary", 200,
                expected_summary(users + 9))

    def check_created(got):
        if got.get("status") != "pending" or not isinstance(got.get("id"), int):
            fail("create order", f"unexpected body {got}")
            return
        if got["id"] <= seeded_orders:
            fail("create order", f"id {got['id']} is not a new row")
        row = psql("SELECT user_id, sku, qty, price_cents, status FROM orders WHERE id = %s", got["id"])
        if row != [["42", "SKU-00042", "3", "1999", "pending"]]:
            fail("create order", f"row in database is {row}")
    expect_json(c, "create order", "POST", "/api/orders", 201,
                body={"user_id": 42, "sku": "SKU-00042", "qty": 3, "price_cents": 1999},
                check=check_created)
    for name, bad in (("qty 0", {"user_id": 1, "sku": "A", "qty": 0, "price_cents": 1}),
                      ("qty 1001", {"user_id": 1, "sku": "A", "qty": 1001, "price_cents": 1}),
                      ("empty sku", {"user_id": 1, "sku": "", "qty": 1, "price_cents": 1}),
                      ("long sku", {"user_id": 1, "sku": "S" * 33, "qty": 1, "price_cents": 1}),
                      ("price 0", {"user_id": 1, "sku": "A", "qty": 1, "price_cents": 0}),
                      ("user 0", {"user_id": 0, "sku": "A", "qty": 1, "price_cents": 1}),
                      ("missing field", {"user_id": 1, "sku": "A", "qty": 1}),
                      ("not json", b"{nope")):
        expect_json(c, f"create order {name}", "POST", "/api/orders", 400, {"error": "bad request"}, body=bad)

    names = sorted(n for n in os.listdir(quote_dir) if n.startswith("quote_"))
    for name in names:
        with open(os.path.join(quote_dir, name), "rb") as f:
            raw = f.read()
        expect_json(c, f"quote {name}", "POST", "/api/quote", 200, expected_quote(json.loads(raw)), body=raw)
    for name, bad in (("unknown region", {"region": "XX", "items": [{"sku": "A", "qty": 1, "price_cents": 1}]}),
                      ("no items", {"region": "US", "items": []}),
                      ("qty 0", {"region": "US", "items": [{"sku": "A", "qty": 0, "price_cents": 1}]})):
        expect_json(c, f"quote {name}", "POST", "/api/quote", 400, {"error": "bad request"}, body=bad)
    # ties: equal nets break by sku, then position
    tie = {"region": "US", "items": [{"sku": "B", "qty": 1, "price_cents": 100},
                                     {"sku": "A", "qty": 1, "price_cents": 100},
                                     {"sku": "C", "qty": 2, "price_cents": 50},
                                     {"sku": "A", "qty": 1, "price_cents": 100},
                                     {"sku": "Z", "qty": 1, "price_cents": 1},
                                     {"sku": "Y", "qty": 1, "price_cents": 1}]}
    expect_json(c, "quote ties", "POST", "/api/quote", 200, expected_quote(tie), body=tie)

    # keep-alive: several requests on one connection, then Connection: close
    k = Client(base)
    for i in range(5):
        st, _, _, err = k.request("GET", "/health")
        if err or st != 200:
            fail("keep-alive", f"request {i + 1} on one connection: {st} {err}")
            break
    st, headers, _, err = k.request("GET", "/health", headers={"Connection": "close"})
    if err or st != 200:
        fail("connection close", f"{st} {err}")

    if failures:
        print(f"FAIL {len(failures)} check(s)")
        for f in failures:
            print("  - " + f)
        return 1
    print("PASS conformance")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
