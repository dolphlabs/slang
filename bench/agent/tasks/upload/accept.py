import os, sys, uuid
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from check import request, check, expect_error, ok

def multipart(field, name, data):
    b = uuid.uuid4().hex
    body = (("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
             "Content-Type: application/octet-stream\r\n\r\n") % (b, field, name)).encode()
    body += data + ("\r\n--%s--\r\n" % b).encode()
    return body, {"Content-Type": "multipart/form-data; boundary=" + b}

data = bytes(range(256)) * 40
body, hd = multipart("file", "report.bin", data)
r = request("POST", "/files", raw=body, headers=hd)
check(r.status == 201, "upload: status %d %r" % (r.status, r.body[:200]))
j = r.json()
check(j.get("name") == "report.bin" and j.get("size") == len(data) and isinstance(j.get("id"), str), "upload body %r" % j)
g = request("GET", "/files/" + j["id"])
check(g.status == 200 and g.body == data, "download returns the exact bytes")
check(g.headers.get("content-type", "").startswith("application/octet-stream"), "download content type")
body, hd = multipart("file", "../../etc/passwd", b"x")
j2 = request("POST", "/files", raw=body, headers=hd).json()
check(j2.get("name") == "passwd", "name reduced to its last component: %r" % j2)
body, hd = multipart("file", "big.bin", b"a" * (1048576 + 1))
expect_error(request("POST", "/files", raw=body, headers=hd), 413, "too_large", "over 1 MiB")
body, hd = multipart("other", "x.bin", b"x")
expect_error(request("POST", "/files", raw=body, headers=hd), 400, "invalid", "no file field")
expect_error(request("POST", "/files", {"file": "x"}), 400, "invalid", "not multipart")
expect_error(request("GET", "/files/nope"), 404, "not_found", "unknown id")
ok("upload")
