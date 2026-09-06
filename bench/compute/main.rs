use std::collections::HashMap;
use std::env;
use std::thread;
use std::time::Instant;

fn getenv_int(name: &str, def: i32) -> i32 {
    match env::var(name) {
        Ok(s) if !s.is_empty() => s.parse().unwrap_or(def),
        _ => def,
    }
}

fn count_primes_range(lo: i32, hi: i32) -> i32 {
    let mut count = 0;
    let mut i = lo;
    while i < hi {
        let mut is_prime = true;
        if i < 2 {
            is_prime = false;
        }
        let mut d = 2;
        while d * d <= i {
            if i % d == 0 {
                is_prime = false;
            }
            d += 1;
        }
        if is_prime {
            count += 1;
        }
        i += 1;
    }
    count
}

fn alloc_and_sum(n: i32) -> i32 {
    let mut xs: Vec<i32> = Vec::with_capacity(n as usize);
    let mut i = 0;
    while i < n {
        xs.push(i);
        i += 1;
    }
    let mut m: HashMap<String, i32> = HashMap::with_capacity(n as usize);
    i = 0;
    while i < n {
        m.insert(i.to_string(), i);
        i += 1;
    }
    let mut sum = 0;
    for v in &xs {
        sum += *v;
    }
    for v in m.values() {
        sum += *v;
    }
    sum
}

fn main() {
    let tasks = getenv_int("CC_TASKS", 1000);
    let work_n = getenv_int("CC_WORK", 20000);
    let alloc_n = getenv_int("CC_ALLOC", 200);
    println!(
        "concurrent_compute: tasks={} work_n={} alloc_n={}",
        tasks, work_n, alloc_n
    );

    let t0 = Instant::now();
    let mut handles = Vec::with_capacity(tasks as usize);
    let mut t = 0;
    while t < tasks {
        let w = work_n;
        let a = alloc_n;
        handles.push(thread::spawn(move || {
            (count_primes_range(0, w), alloc_and_sum(a))
        }));
        t += 1;
    }
    let mut total_primes = 0i32;
    let mut total_alloc = 0i32;
    for h in handles {
        let (p, a) = h.join().expect("thread");
        total_primes += p;
        total_alloc += a;
    }
    let elapsed_ms = t0.elapsed().as_millis() as i64;
    let tps = if elapsed_ms > 0 {
        (tasks as i64) * 1000 / elapsed_ms
    } else {
        0
    };
    println!(
        "RESULT tasks={} work_n={} alloc_n={} wall_ms={} total_primes={} total_alloc_sum={} tasks_per_sec={}",
        tasks, work_n, alloc_n, elapsed_ms, total_primes, total_alloc, tps
    );
}
