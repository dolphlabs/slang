import threading
from base import Handler, serve

notes, next_id, lock = {}, [1], threading.Lock()

def valid(j):
    if not isinstance(j, dict): return "body must be a JSON object"
    t = j.get("title")
    if not isinstance(t, str) or not 1 <= len(t) <= 100: return "title must be 1 to 100 characters"
    if not isinstance(j.get("body"), str): return "body must be a string"
    return None

def create(h, m):
    j = h.json_body(); e = valid(j)
    if e: return h.err(400, "invalid", e)
    with lock:
        n = {"id": next_id[0], "title": j["title"], "body": j["body"]}; notes[n["id"]] = n; next_id[0] += 1
    h.send(201, n)

def list_(h, m): h.send(200, [notes[k] for k in sorted(notes)])
def get(h, m):
    n = notes.get(int(m.group(1)))
    return h.send(200, n) if n else h.err(404, "not_found", "no such note")
def put(h, m):
    i = int(m.group(1)); j = h.json_body(); e = valid(j)
    if i not in notes: return h.err(404, "not_found", "no such note")
    if e: return h.err(400, "invalid", e)
    notes[i].update(title=j["title"], body=j["body"]); h.send(200, notes[i])
def delete(h, m):
    i = int(m.group(1))
    if notes.pop(i, None) is None: return h.err(404, "not_found", "no such note")
    h.send(204)

class H(Handler):
    routes = [("POST", r"/notes", create), ("GET", r"/notes", list_), ("GET", r"/notes/(\d+)", get),
              ("PUT", r"/notes/(\d+)", put), ("DELETE", r"/notes/(\d+)", delete)]
serve(H)
