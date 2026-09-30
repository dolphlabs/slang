import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from check import request, check, expect_error, ok

r = request("GET", "/health")
check(r.status == 200 and r.json() == {"ok": True}, "health is public")
expect_error(request("POST", "/login", {"user": "alice", "password": "nope"}), 401, "unauthorized", "wrong password")
expect_error(request("POST", "/login", {"user": "mallory", "password": "x"}), 401, "unauthorized", "unknown user")
r1 = request("POST", "/login", {"user": "alice", "password": "wonderland"})
check(r1.status == 200 and isinstance(r1.json().get("token"), str), "alice logs in")
t1 = r1.json()["token"]
check(len(t1) >= 16, "token is long enough to hold 128 bits")
t2 = request("POST", "/login", {"user": "alice", "password": "wonderland"}).json()["token"]
check(t1 != t2, "each login issues a new token")
tb = request("POST", "/login", {"user": "bob", "password": "builder"}).json()["token"]
auth = lambda t: {"Authorization": "Bearer " + t}
check(request("GET", "/me", headers=auth(t1)).json() == {"user": "alice"}, "me as alice")
check(request("GET", "/me", headers=auth(tb)).json() == {"user": "bob"}, "me as bob")
expect_error(request("GET", "/me"), 401, "unauthorized", "no token")
expect_error(request("GET", "/me", headers={"Authorization": "Token " + t1}), 401, "unauthorized", "wrong scheme")
expect_error(request("GET", "/me", headers=auth(t1 + "x")), 401, "unauthorized", "unknown token")
r = request("POST", "/logout", headers=auth(t1))
check(r.status == 204, "logout: 204")
expect_error(request("GET", "/me", headers=auth(t1)), 401, "unauthorized", "token dead after logout")
check(request("GET", "/me", headers=auth(t2)).status == 200, "other token of the same user still works")
ok("auth")
