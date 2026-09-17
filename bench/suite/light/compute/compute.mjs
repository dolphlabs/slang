// light/compute for Node and Bun: CC_TASKS tasks spread over one
// worker_thread per core, each task doing exactly bench/compute/main.go's
// work. See bench/SPEC.md.
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import os from "node:os";

function countPrimesRange(lo, hi) {
  let count = 0;
  for (let i = lo; i < hi; i++) {
    let isPrime = i >= 2;
    for (let d = 2; d * d <= i; d++) {
      if (i % d === 0) isPrime = false;
    }
    if (isPrime) count++;
  }
  return count;
}

function allocAndSum(n) {
  const xs = [];
  for (let i = 0; i < n; i++) xs.push(i);
  const m = new Map();
  for (let i = 0; i < n; i++) m.set(String(i), i);
  let sum = 0;
  for (const v of xs) sum += v;
  for (const v of m.values()) sum += v;
  return sum;
}

if (!isMainThread) {
  const { tasks, work, alloc } = workerData;
  let primes = 0, allocSum = 0;
  for (let t = 0; t < tasks; t++) {
    primes += countPrimesRange(0, work);
    allocSum += allocAndSum(alloc);
  }
  parentPort.postMessage({ primes, allocSum });
} else {
  const tasks = Number(process.env.CC_TASKS) || 1000;
  const work = Number(process.env.CC_WORK) || 20000;
  const alloc = Number(process.env.CC_ALLOC) || 200;
  const threads = Math.min(tasks, Number(process.env.WORKERS) || os.availableParallelism());
  console.log(`concurrent_compute: tasks=${tasks} work_n=${work} alloc_n=${alloc}`);
  const t0 = performance.now();
  const results = await Promise.all(Array.from({ length: threads }, (_, i) => {
    const share = Math.floor(tasks / threads) + (i < tasks % threads ? 1 : 0);
    return new Promise((resolve, reject) => {
      const w = new Worker(new URL(import.meta.url), { workerData: { tasks: share, work, alloc } });
      w.once("message", resolve);
      w.once("error", reject);
    });
  }));
  const wall = Math.round(performance.now() - t0);
  const primes = results.reduce((a, r) => a + r.primes, 0);
  const allocSum = results.reduce((a, r) => a + r.allocSum, 0);
  const tps = wall > 0 ? Math.floor(tasks * 1000 / wall) : 0;
  console.log(`RESULT tasks=${tasks} work_n=${work} alloc_n=${alloc} wall_ms=${wall} total_primes=${primes} total_alloc_sum=${allocSum} tasks_per_sec=${tps}`);
}
