"""Shared helpers for the acceptance tests: HTTP over the standard library
only, so the harness runs anywhere Python 3 does. Each task's accept.py
imports this and calls check(...) for every requirement; the process exits
1 on the first failure, printing which requirement it was."""

import http.client
import json
import os
import sys

PORT = int(os.environ.get("PORT", "8080"))


class Resp:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = {k.lower(): v for k, v in headers}
        self.body = body

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8"))
        except ValueError:
            fail("response is not JSON: %r" % self.body[:200])


def request(method, path, body=None, headers=None, raw=None):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    h = dict(headers or {})
    data = raw
    if body is not None:
        data = json.dumps(body).encode()
        h.setdefault("Content-Type", "application/json")
    conn.request(method, path, body=data, headers=h)
    r = conn.getresponse()
    out = Resp(r.status, r.getheaders(), r.read())
    conn.close()
    return out


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def check(cond, msg):
    if not cond:
        fail(msg)


def expect_error(r, status, code, what):
    check(r.status == status, "%s: status %d, want %d (body %r)"
          % (what, r.status, status, r.body[:200]))
    j = r.json()
    check(isinstance(j, dict) and isinstance(j.get("error"), dict),
          "%s: body is not an error envelope: %r" % (what, j))
    check(j["error"].get("code") == code, "%s: code %r, want %r"
          % (what, j["error"].get("code"), code))
    check(isinstance(j["error"].get("message"), str) and j["error"]["message"],
          "%s: error has no message" % what)
    return j


def ok(name):
    print("PASS " + name)
