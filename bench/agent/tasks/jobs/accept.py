import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from check import request, check, expect_error, ok

def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a

expect_error(request("POST", "/jobs", {"n": 0, "delay_ms": 0}), 400, "invalid", "n below range")
expect_error(request("POST", "/jobs", {"n": 41, "delay_ms": 0}), 400, "invalid", "n above range")
expect_error(request("POST", "/jobs", {"n": 5, "delay_ms": 2001}), 400, "invalid", "delay above range")
t0 = time.time()
r = request("POST", "/jobs", {"n": 10, "delay_ms": 700})
took = time.time() - t0
check(r.status == 202 and r.json() == {"id": 1, "status": "queued"}, "submit: %r" % r.body)
check(took < 0.4, "submit returned before the job finished (%.2fs)" % took)
s = request("GET", "/jobs/1").json()
check(s["status"] in ("queued", "running"), "not done right away")
deadline = time.time() + 5
while time.time() < deadline:
    s = request("GET", "/jobs/1").json()
    if s["status"] == "done":
        break
    time.sleep(0.05)
check(s == {"id": 1, "status": "done", "result": fib(10)}, "done with result: %r" % s)
expect_error(request("GET", "/jobs/999"), 404, "not_found", "unknown job")
ids = [request("POST", "/jobs", {"n": 40, "delay_ms": 500}).json()["id"] for _ in range(4)]
t0 = time.time()
while time.time() - t0 < 3:
    states = [request("GET", "/jobs/%d" % i).json() for i in ids]
    if all(s["status"] == "done" for s in states):
        break
    time.sleep(0.05)
check(all(s["status"] == "done" and s["result"] == fib(40) for s in states), "4 jobs done: %r" % states)
check(time.time() - t0 < 1.5, "4 x 500ms jobs ran concurrently (%.2fs)" % (time.time() - t0))
ok("jobs")
