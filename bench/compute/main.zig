const std = @import("std");

fn getenvInt(name: []const u8, def: i32) i32 {
    const s = std.posix.getenv(name) orelse return def;
    if (s.len == 0) return def;
    return std.fmt.parseInt(i32, s, 10) catch def;
}

fn countPrimesRange(lo: i32, hi: i32) i32 {
    var count: i32 = 0;
    var i = lo;
    while (i < hi) : (i += 1) {
        var is_prime = true;
        if (i < 2) is_prime = false;
        var d: i32 = 2;
        while (d * d <= i) : (d += 1) {
            if (@rem(i, d) == 0) is_prime = false;
        }
        if (is_prime) count += 1;
    }
    return count;
}

fn allocAndSum(allocator: std.mem.Allocator, n: i32) !i32 {
    var xs = std.ArrayList(i32).init(allocator);
    defer xs.deinit();
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        try xs.append(i);
    }
    var m = std.StringHashMap(i32).init(allocator);
    defer {
        var kit = m.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        m.deinit();
    }
    i = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
        try m.put(key, i);
    }
    var sum: i32 = 0;
    for (xs.items) |v| sum += v;
    var vit = m.valueIterator();
    while (vit.next()) |v| sum += v.*;
    return sum;
}

const Worker = struct {
    work_n: i32,
    alloc_n: i32,
    primes: i32 = 0,
    alloc_sum: i32 = 0,
};

fn worker(w: *Worker) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    w.primes = countPrimesRange(0, w.work_n);
    w.alloc_sum = allocAndSum(gpa.allocator(), w.alloc_n) catch {
        std.process.exit(1);
    };
}

pub fn main() !void {
    const tasks = getenvInt("CC_TASKS", 1000);
    const work_n = getenvInt("CC_WORK", 20000);
    const alloc_n = getenvInt("CC_ALLOC", 200);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("concurrent_compute: tasks={d} work_n={d} alloc_n={d}\n", .{ tasks, work_n, alloc_n });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const n: usize = @intCast(tasks);
    const args = try allocator.alloc(Worker, n);
    defer allocator.free(args);
    const threads = try allocator.alloc(std.Thread, n);
    defer allocator.free(threads);

    var t: usize = 0;
    while (t < n) : (t += 1) {
        args[t] = .{ .work_n = work_n, .alloc_n = alloc_n };
    }

    const t0 = std.time.milliTimestamp();
    t = 0;
    while (t < n) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, worker, .{&args[t]});
    }
    var total_primes: i32 = 0;
    var total_alloc: i32 = 0;
    t = 0;
    while (t < n) : (t += 1) {
        threads[t].join();
        total_primes += args[t].primes;
        total_alloc += args[t].alloc_sum;
    }
    const elapsed_ms = std.time.milliTimestamp() - t0;
    const tps: i64 = if (elapsed_ms > 0) @divTrunc(@as(i64, tasks) * 1000, elapsed_ms) else 0;
    try stdout.print(
        "RESULT tasks={d} work_n={d} alloc_n={d} wall_ms={d} total_primes={d} total_alloc_sum={d} tasks_per_sec={d}\n",
        .{ tasks, work_n, alloc_n, elapsed_ms, total_primes, total_alloc, tps },
    );
}
