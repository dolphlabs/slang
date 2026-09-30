import os, re, uuid
from base import Handler, serve

files = {}
LIMIT = 1048576

def upload(h, m):
    ct = h.headers.get("Content-Type", "")
    mb = re.match(r'multipart/form-data;\s*boundary=(.+)', ct)
    if not mb: return h.err(400, "invalid", "expected multipart/form-data")
    raw = h.body(); b = ("--" + mb.group(1).strip('"')).encode()
    for part in raw.split(b)[1:]:
        if part.startswith(b"--"): break
        head, _, data = part.partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        d = re.search(rb'name="([^"]*)"(?:; filename="([^"]*)")?', head)
        if d and d.group(1) == b"file" and d.group(2) is not None:
            if len(data) > LIMIT: return h.err(413, "too_large", "file over 1 MiB")
            name = os.path.basename(d.group(2).decode().replace("\\", "/")) or "file"
            i = uuid.uuid4().hex; files[i] = data
            return h.send(201, {"id": i, "name": name, "size": len(data)})
    h.err(400, "invalid", "no file field")
def get(h, m):
    d = files.get(m.group(1))
    return h.send(200, raw=d, ctype="application/octet-stream") if d is not None else h.err(404, "not_found", "no such file")

class H(Handler):
    routes = [("POST", r"/files", upload), ("GET", r"/files/([0-9a-z]+)", get)]
serve(H)
