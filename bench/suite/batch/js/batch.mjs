// heavy/batch for Node and Bun: worker_threads over newline-aligned byte
// ranges read with positional fs.readSync, Maps per worker merged at the
// end. The same file runs on both runtimes. See bench/SPEC.md.
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import fs from "node:fs";
import os from "node:os";

const BLOCK = 16 * 1024 * 1024;

function work({ path, start, end }) {
  const fd = fs.openSync(path, "r");
  const regions = new Float64Array(676 * 3); // count, qty, revenue per code
  const users = new Map();
  const skus = new Map();
  let rows = 0;
  let buf = Buffer.allocUnsafe(BLOCK + 256);
  let carry = 0;
  let pos = start;
  while (pos < end) {
    const want = Math.min(BLOCK, end - pos);
    if (carry + want > buf.length) {
      const nb = Buffer.allocUnsafe(carry + want);
      buf.copy(nb, 0, 0, carry);
      buf = nb;
    }
    const got = fs.readSync(fd, buf, carry, want, pos);
    pos += got;
    const len = carry + got;
    let last = len - 1;
    while (last >= 0 && buf[last] !== 10) last--;
    let i = 0;
    while (i <= last) {
      while (buf[i] !== 44) i++;
      i++;
      let user = 0;
      while (buf[i] !== 44) user = user * 10 + (buf[i++] - 48);
      i++;
      const skuStart = i;
      while (buf[i] !== 44) i++;
      const sku = buf.latin1Slice(skuStart, i);
      i++;
      let qty = 0;
      while (buf[i] !== 44) qty = qty * 10 + (buf[i++] - 48);
      i++;
      let price = 0;
      while (buf[i] !== 44) price = price * 10 + (buf[i++] - 48);
      i++;
      const r = ((buf[i] - 65) * 26 + (buf[i + 1] - 65)) * 3;
      i += 3;
      const rev = qty * price;
      regions[r] += 1;
      regions[r + 1] += qty;
      regions[r + 2] += rev;
      rows++;
      users.set(user, (users.get(user) || 0) + rev);
      skus.set(sku, (skus.get(sku) || 0) + rev);
    }
    carry = len - (last + 1);
    buf.copy(buf, 0, last + 1, len);
  }
  fs.closeSync(fd);
  return { rows, regions, users: [...users], skus: [...skus] };
}

if (!isMainThread) {
  parentPort.postMessage(work(workerData));
} else {
  const path = process.argv[2];
  const size = fs.statSync(path).size;
  let workers = Number(process.env.WORKERS) || os.availableParallelism();
  workers = Math.min(workers, Math.floor(size / 65536) + 1);

  const fd = fs.openSync(path, "r");
  const probe = Buffer.allocUnsafe(4096);
  const bounds = [0];
  for (let w = 1; w < workers; w++) {
    let at = Math.floor(size / workers) * w;
    let found = size;
    for (let p = at - 1; p < size;) {
      const got = fs.readSync(fd, probe, 0, 4096, p);
      if (got === 0) break;
      const nl = probe.subarray(0, got).indexOf(10);
      if (nl >= 0) { found = p + nl + 1; break; }
      p += got;
    }
    bounds.push(Math.max(found, bounds[bounds.length - 1]));
  }
  bounds.push(size);
  fs.closeSync(fd);

  const parts = await Promise.all(bounds.slice(0, -1).map((start, w) => new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), { workerData: { path, start, end: bounds[w + 1] } });
    worker.once("message", resolve);
    worker.once("error", reject);
  })));

  let rows = 0;
  const regions = new Float64Array(676 * 3);
  const users = new Map();
  const skus = new Map();
  for (const p of parts) {
    rows += p.rows;
    for (let k = 0; k < regions.length; k++) regions[k] += p.regions[k];
    for (const [u, v] of p.users) users.set(u, (users.get(u) || 0) + v);
    for (const [s, v] of p.skus) skus.set(s, (skus.get(s) || 0) + v);
  }

  const topRev = [], topUser = [];
  for (const [u, v] of users) {
    let n = topRev.length;
    if (n === 100 && !(v > topRev[99] || (v === topRev[99] && u < topUser[99]))) continue;
    if (n === 100) { topRev.pop(); topUser.pop(); n--; }
    let at = n;
    while (at > 0 && (v > topRev[at - 1] || (v === topRev[at - 1] && u < topUser[at - 1]))) at--;
    topRev.splice(at, 0, v);
    topUser.splice(at, 0, u);
  }
  const topSkus = [...skus].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)).slice(0, 10);

  const lines = [`rows=${rows}`];
  for (let c = 0; c < 676; c++) {
    if (regions[c * 3] > 0) {
      const code = String.fromCharCode(65 + Math.floor(c / 26), 65 + (c % 26));
      lines.push(`region=${code} count=${regions[c * 3]} qty=${regions[c * 3 + 1]} revenue=${regions[c * 3 + 2]}`);
    }
  }
  topRev.forEach((v, i) => lines.push(`top_user rank=${i + 1} user_id=${topUser[i]} revenue=${v}`));
  topSkus.forEach(([s, v], i) => lines.push(`top_sku rank=${i + 1} sku=${s} revenue=${v}`));
  process.stdout.write(lines.join("\n") + "\n");
}
