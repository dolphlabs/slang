"""Minimal stdlib HTTP plumbing for the reference servers. They exist only
to prove each acceptance test is correct and passable; they are not an
entry in the comparison."""

import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    routes = []  # (method, regex, fn(self, match))

    def log_message(self, *a):
        pass

    def send(self, status, obj=None, raw=None, ctype="application/json", headers=None):
        body = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(status)
        if body or obj is not None:
            self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def err(self, status, code, msg, headers=None):
        self.send(status, {"error": {"code": code, "message": msg}}, headers=headers)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def json_body(self):
        try:
            return json.loads(self.body().decode())
        except (ValueError, UnicodeDecodeError):
            return None

    def dispatch(self, method):
        for m, rx, fn in self.routes:
            mt = re.fullmatch(rx, self.path.split("?")[0])
            if m == method and mt:
                return fn(self, mt)
        self.err(404, "not_found", "no such route")

    def do_GET(self): self.dispatch("GET")
    def do_POST(self): self.dispatch("POST")
    def do_PUT(self): self.dispatch("PUT")
    def do_DELETE(self): self.dispatch("DELETE")


def serve(handler):
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
