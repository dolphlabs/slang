package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

func getenvInt(name string, def int) int {
	s := os.Getenv(name)
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

func countPrimesRange(lo, hi int) int {
	count := 0
	for i := lo; i < hi; i++ {
		isPrime := true
		if i < 2 {
			isPrime = false
		}
		for d := 2; d*d <= i; d++ {
			if i%d == 0 {
				isPrime = false
			}
		}
		if isPrime {
			count++
		}
	}
	return count
}

func allocAndSum(n int) int {
	xs := make([]int, 0, n)
	for i := 0; i < n; i++ {
		xs = append(xs, i)
	}
	m := make(map[string]int, n)
	for i := 0; i < n; i++ {
		m[strconv.Itoa(i)] = i
	}
	sum := 0
	for _, v := range xs {
		sum += v
	}
	for _, v := range m {
		sum += v
	}
	return sum
}

type taskResult struct {
	primes   int
	allocSum int
}

func main() {
	tasks := getenvInt("CC_TASKS", 1000)
	workN := getenvInt("CC_WORK", 20000)
	allocN := getenvInt("CC_ALLOC", 200)
	fmt.Printf("concurrent_compute: tasks=%d work_n=%d alloc_n=%d\n", tasks, workN, allocN)

	ch := make(chan taskResult, tasks)
	t0 := time.Now()
	var wg sync.WaitGroup
	wg.Add(tasks)
	for i := 0; i < tasks; i++ {
		go func() {
			defer wg.Done()
			ch <- taskResult{
				primes:   countPrimesRange(0, workN),
				allocSum: allocAndSum(allocN),
			}
		}()
	}
	go func() {
		wg.Wait()
		close(ch)
	}()

	totalPrimes := 0
	totalAlloc := 0
	for r := range ch {
		totalPrimes += r.primes
		totalAlloc += r.allocSum
	}
	elapsedMs := time.Since(t0).Milliseconds()
	tps := 0
	if elapsedMs > 0 {
		tps = int(int64(tasks) * 1000 / elapsedMs)
	}
	fmt.Printf("RESULT tasks=%d work_n=%d alloc_n=%d wall_ms=%d total_primes=%d total_alloc_sum=%d tasks_per_sec=%d\n",
		tasks, workN, allocN, elapsedMs, totalPrimes, totalAlloc, tps)
}
