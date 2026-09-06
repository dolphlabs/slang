import "time";
import "proc";

extern fn atoi(s: str) -> i32;

fn count_primes_range(lo: int, hi: int) -> int {
    let count = 0;
    for i in lo..hi {
        let is_prime = true;
        if i < 2 { is_prime = false; }
        let d = 2;
        while d * d <= i {
            if i % d == 0 { is_prime = false; }
            d = d + 1;
        }
        if is_prime { count = count + 1; }
    }
    return count;
}

fn alloc_and_sum(n: int) -> int {
    let a = arena_new(n * 32 + 256);
    let sum = 0;
    for i in 0..n {
        let p = a.alloc(i);
        sum = sum + *p;
    }
    for i in 0..n {
        sum = sum + i;
    }
    return sum;
}

pub struct TaskResult {
    primes: int,
    alloc_sum: int,
}

fn worker(work_n: int, alloc_n: int, results: chan[TaskResult]) {
    let primes = count_primes_range(0, work_n);
    let alloc_sum = alloc_and_sum(alloc_n);
    chan_send(results, TaskResult { primes: primes, alloc_sum: alloc_sum });
}

let tasks_str: str = proc.getenv("CC_TASKS") ?? "1000";
let tasks = atoi(tasks_str);
let work_str: str = proc.getenv("CC_WORK") ?? "20000";
let work_n = atoi(work_str);
let alloc_str: str = proc.getenv("CC_ALLOC") ?? "200";
let alloc_n = atoi(alloc_str);

println("concurrent_compute_arena: tasks=" + to_str(tasks)
        + " work_n=" + to_str(work_n) + " alloc_n=" + to_str(alloc_n));

let results: chan[TaskResult] = make_chan(tasks);
let t0 = time.mono();
for i in 0..tasks {
    spawn worker(work_n, alloc_n, results);
}

let total_primes = 0;
let total_alloc = 0;
for j in 0..tasks {
    let v = chan_recv(results);
    guard let r = v else {
        println("FAIL: results channel closed unexpectedly");
        exit(1);
    }
    total_primes = total_primes + r.primes;
    total_alloc = total_alloc + r.alloc_sum;
}
let elapsed: duration = time.mono() - t0;
let elapsed_ms = (elapsed as int) / 1000000;
let tasks_per_sec = 0;
if elapsed_ms > 0 {
    tasks_per_sec = (tasks * 1000) / elapsed_ms;
}

println("RESULT tasks=" + to_str(tasks)
        + " work_n=" + to_str(work_n)
        + " alloc_n=" + to_str(alloc_n)
        + " wall_ms=" + to_str(elapsed_ms)
        + " total_primes=" + to_str(total_primes)
        + " total_alloc_sum=" + to_str(total_alloc)
        + " tasks_per_sec=" + to_str(tasks_per_sec)
        + " active_tasks_after=" + to_str(proc.active_tasks()));
