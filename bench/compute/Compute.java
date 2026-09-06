import java.util.ArrayList;
import java.util.HashMap;

public class Compute {
    static int getenvInt(String name, int def) {
        String s = System.getenv(name);
        if (s == null || s.isEmpty())
            return def;
        try {
            return Integer.parseInt(s);
        } catch (NumberFormatException e) {
            return def;
        }
    }

    static int countPrimesRange(int lo, int hi) {
        int count = 0;
        for (int i = lo; i < hi; i++) {
            boolean isPrime = true;
            if (i < 2)
                isPrime = false;
            for (int d = 2; d * d <= i; d++) {
                if (i % d == 0)
                    isPrime = false;
            }
            if (isPrime)
                count++;
        }
        return count;
    }

    static int allocAndSum(int n) {
        ArrayList<Integer> xs = new ArrayList<>(n);
        for (int i = 0; i < n; i++)
            xs.add(i);
        HashMap<String, Integer> m = new HashMap<>(n);
        for (int i = 0; i < n; i++)
            m.put(Integer.toString(i), i);
        int sum = 0;
        for (int v : xs)
            sum += v;
        for (int v : m.values())
            sum += v;
        return sum;
    }

    public static void main(String[] args) throws InterruptedException {
        int tasks = getenvInt("CC_TASKS", 1000);
        int workN = getenvInt("CC_WORK", 20000);
        int allocN = getenvInt("CC_ALLOC", 200);
        System.out.printf("concurrent_compute: tasks=%d work_n=%d alloc_n=%d%n", tasks, workN, allocN);

        int[] primes = new int[tasks];
        int[] allocs = new int[tasks];
        Thread[] th = new Thread[tasks];
        long t0 = System.nanoTime();
        for (int t = 0; t < tasks; t++) {
            final int idx = t;
            th[t] = new Thread(() -> {
                primes[idx] = countPrimesRange(0, workN);
                allocs[idx] = allocAndSum(allocN);
            });
            th[t].start();
        }
        int totalPrimes = 0;
        int totalAlloc = 0;
        for (int t = 0; t < tasks; t++) {
            th[t].join();
            totalPrimes += primes[t];
            totalAlloc += allocs[t];
        }
        long elapsedMs = (System.nanoTime() - t0) / 1_000_000L;
        long tps = elapsedMs > 0 ? (tasks * 1000L) / elapsedMs : 0;
        System.out.printf(
            "RESULT tasks=%d work_n=%d alloc_n=%d wall_ms=%d total_primes=%d total_alloc_sum=%d tasks_per_sec=%d%n",
            tasks, workN, allocN, elapsedMs, totalPrimes, totalAlloc, tps);
    }
}
