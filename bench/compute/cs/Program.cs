using System.Diagnostics;

static int getenvInt(string name, int def)
{
    var s = Environment.GetEnvironmentVariable(name);
    if (string.IsNullOrEmpty(s)) return def;
    return int.TryParse(s, out var n) ? n : def;
}

static int countPrimesRange(int lo, int hi)
{
    var count = 0;
    for (var i = lo; i < hi; i++)
    {
        var isPrime = true;
        if (i < 2) isPrime = false;
        for (var d = 2; d * d <= i; d++)
        {
            if (i % d == 0) isPrime = false;
        }
        if (isPrime) count++;
    }
    return count;
}

static int allocAndSum(int n)
{
    var xs = new List<int>(n);
    for (var i = 0; i < n; i++)
        xs.Add(i);
    var m = new Dictionary<string, int>(n);
    for (var i = 0; i < n; i++)
        m[i.ToString()] = i;
    var sum = 0;
    foreach (var v in xs) sum += v;
    foreach (var v in m.Values) sum += v;
    return sum;
}

var tasks = getenvInt("CC_TASKS", 1000);
var workN = getenvInt("CC_WORK", 20000);
var allocN = getenvInt("CC_ALLOC", 200);
Console.WriteLine($"concurrent_compute: tasks={tasks} work_n={workN} alloc_n={allocN}");

var primes = new int[tasks];
var allocs = new int[tasks];
var threads = new Thread[tasks];
var sw = Stopwatch.StartNew();
for (var t = 0; t < tasks; t++)
{
    var idx = t;
    threads[t] = new Thread(() =>
    {
        primes[idx] = countPrimesRange(0, workN);
        allocs[idx] = allocAndSum(allocN);
    });
    threads[t].Start();
}
var totalPrimes = 0;
var totalAlloc = 0;
for (var t = 0; t < tasks; t++)
{
    threads[t].Join();
    totalPrimes += primes[t];
    totalAlloc += allocs[t];
}
sw.Stop();
var elapsedMs = sw.ElapsedMilliseconds;
var tps = elapsedMs > 0 ? tasks * 1000L / elapsedMs : 0;
Console.WriteLine(
    $"RESULT tasks={tasks} work_n={workN} alloc_n={allocN} wall_ms={elapsedMs} total_primes={totalPrimes} total_alloc_sum={totalAlloc} tasks_per_sec={tps}");
