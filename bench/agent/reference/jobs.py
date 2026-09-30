import threading, time
from base import Handler, serve

jobs, lock, next_id = {}, threading.Lock(), [1]

def run(job, delay):
    job["status"] = "running"; time.sleep(delay / 1000)
    a, b = 0, 1
    for _ in range(job["n"]): a, b = b, a + b
    job["result"] = a; job["status"] = "done"

def submit(h, m):
    j = h.json_body()
    ok = isinstance(j, dict) and type(j.get("n")) is int and 1 <= j["n"] <= 40 and \
         type(j.get("delay_ms")) is int and 0 <= j["delay_ms"] <= 2000
    if not ok: return h.err(400, "invalid", "n must be 1..40 and delay_ms 0..2000")
    with lock:
        i = next_id[0]; next_id[0] += 1; job = {"id": i, "status": "queued", "n": j["n"]}; jobs[i] = job
    h.send(202, {"id": i, "status": "queued"})
    threading.Thread(target=run, args=(job, j["delay_ms"]), daemon=True).start()
def get(h, m):
    job = jobs.get(int(m.group(1)))
    if not job: return h.err(404, "not_found", "no such job")
    out = {"id": job["id"], "status": job["status"]}
    if job["status"] == "done": out["result"] = job["result"]
    h.send(200, out)

class H(Handler):
    routes = [("POST", r"/jobs", submit), ("GET", r"/jobs/(\d+)", get)]
serve(H)
