// The Go side of bench/cache/run.sh: the same workload against
// hashicorp/golang-lru/v2 and dgraph-io/ristretto/v2.
//
//	bench lru|ristretto single|parallel|fill
package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	lru "github.com/hashicorp/golang-lru/v2"
	"github.com/dgraph-io/ristretto/v2"
)

type cache interface {
	get(k string) (int, bool)
	put(k string, v int)
	size() int
}

type lruC struct{ c *lru.Cache[string, int] }

func (l lruC) get(k string) (int, bool) { return l.c.Get(k) }
func (l lruC) put(k string, v int)      { l.c.Add(k, v) }
func (l lruC) size() int                { return l.c.Len() }

type risC struct{ c *ristretto.Cache[string, int] }

func (r risC) get(k string) (int, bool) { return r.c.Get(k) }
func (r risC) put(k string, v int)      { r.c.Set(k, v, 1) }
func (r risC) size() int                { r.c.Wait(); return int(r.c.Metrics.KeysAdded() - r.c.Metrics.KeysEvicted()) }

func make_(kind string, max int) cache {
	if kind == "lru" {
		c, _ := lru.New[string, int](max)
		return lruC{c}
	}
	c, err := ristretto.NewCache(&ristretto.Config[string, int]{NumCounters: int64(max) * 10, MaxCost: int64(max),
		BufferItems: 64, Metrics: true})
	if err != nil {
		panic(err)
	}
	return risC{c}
}

func keys(n int) []string {
	ks := make([]string, n)
	for i := 0; i < n; i++ {
		ks[i] = "user:" + strconv.Itoa(i*7919%1000003)
	}
	return ks
}

func draw(state *int64, n int) int {
	x := *state
	x ^= x << 13
	x ^= (x >> 7) & 144115188075855871
	x ^= x << 17
	*state = x
	u := float64(x&1048575) / 1048576.0
	return int(u * u * float64(n))
}

func work(c cache, ks []string, ops int, seed int64) int {
	state := seed
	hits := 0
	for i := 0; i < ops; i++ {
		k := draw(&state, len(ks))
		if i%10 == 0 {
			c.put(ks[k], k)
		} else if _, ok := c.get(ks[k]); ok {
			hits++
		}
	}
	return hits
}

func main() {
	kind, mode := os.Args[1], os.Args[2]
	if mode == "fill" {
		ks := keys(1000000)
		c := make_(kind, 1000000)
		for i := 0; i < 1000000; i++ {
			c.put(ks[i], i)
		}
		fmt.Printf("entries=%d\n", c.size())
		return
	}
	ks := keys(100000)
	c := make_(kind, 10000)
	tasks, ops := 1, 1000000
	if mode == "parallel" {
		tasks, ops = 8, 500000
	}
	t0 := time.Now()
	hits := 0
	if tasks == 1 {
		hits = work(c, ks, ops, 88172645463325252)
	} else {
		var wg sync.WaitGroup
		var mu sync.Mutex
		for t := 0; t < tasks; t++ {
			wg.Add(1)
			go func(t int) {
				defer wg.Done()
				h := work(c, ks, ops, 88172645463325252+int64(t)*1000003)
				mu.Lock()
				hits += h
				mu.Unlock()
			}(t)
		}
		wg.Wait()
	}
	ns := time.Since(t0).Nanoseconds()
	total := tasks * ops
	fmt.Printf("ns_per_op=%d hit_rate=%d/1000\n", ns/int64(total), hits*1000/(total*9/10))
}
