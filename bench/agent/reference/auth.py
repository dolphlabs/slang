import secrets
from base import Handler, serve

USERS = {"alice": "wonderland", "bob": "builder"}
tokens = {}

def user_of(h):
    a = h.headers.get("Authorization", "")
    return tokens.get(a[7:]) if a.startswith("Bearer ") else None

def login(h, m):
    j = h.json_body() or {}
    if not isinstance(j, dict) or USERS.get(j.get("user")) != j.get("password") or j.get("user") not in USERS:
        return h.err(401, "unauthorized", "wrong user or password")
    t = secrets.token_urlsafe(24); tokens[t] = j["user"]; h.send(200, {"token": t})
def me(h, m):
    u = user_of(h)
    return h.send(200, {"user": u}) if u else h.err(401, "unauthorized", "missing or unknown token")
def logout(h, m):
    if not user_of(h): return h.err(401, "unauthorized", "missing or unknown token")
    tokens.pop(h.headers["Authorization"][7:]); h.send(204)

class H(Handler):
    routes = [("GET", r"/health", lambda h, m: h.send(200, {"ok": True})), ("POST", r"/login", login),
              ("GET", r"/me", me), ("POST", r"/logout", logout)]
serve(H)
