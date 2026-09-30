import math, threading, time
from base import Handler, serve

hits, lock = {}, threading.Lock()

def ping(h, m):
    c = h.headers.get("X-Client-Id") or "anonymous"; now = time.monotonic()
    with lock:
        q = [t for t in hits.get(c, []) if now - t < 1.0]
        if len(q) >= 5:
            hits[c] = q
            wait = max(1, math.ceil(1.0 - (now - q[0])))
            return h.err(429, "rate_limited", "too many requests", headers={"Retry-After": str(wait)})
        q.append(now); hits[c] = q
    h.send(200, {"pong": True})

class H(Handler):
    routes = [("GET", r"/ping", ping)]
serve(H)
