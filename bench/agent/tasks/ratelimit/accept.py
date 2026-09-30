import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from check import request, check, expect_error, ok

h = lambda c: {"X-Client-Id": c}
for i in range(5):
    r = request("GET", "/ping", headers=h("a"))
    check(r.status == 200 and r.json() == {"pong": True}, "request %d of 5 allowed" % (i + 1))
r = request("GET", "/ping", headers=h("a"))
expect_error(r, 429, "rate_limited", "6th request in a second")
ra = r.headers.get("retry-after", "")
check(ra.isdigit() and int(ra) >= 1, "Retry-After is whole seconds >= 1: %r" % ra)
check(request("GET", "/ping", headers=h("b")).status == 200, "other clients unaffected")
for i in range(5):
    request("GET", "/ping")
expect_error(request("GET", "/ping"), 429, "rate_limited", "no header counts as one client")
time.sleep(1.2)
check(request("GET", "/ping", headers=h("a")).status == 200, "allowed again after the window")
ok("ratelimit")
