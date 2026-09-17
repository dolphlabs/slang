// heavy/batch in Go: mmap, a goroutine per core over newline-aligned
// ranges, per-goroutine maps merged at the end. See bench/SPEC.md.
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"syscall"
)

const skuMax = 16

type skuKey struct {
	b [skuMax]byte
	n uint8
}

func (k skuKey) String() string { return string(k.b[:k.n]) }

func less(a, b skuKey) bool { return bytes.Compare(a.b[:a.n], b.b[:b.n]) < 0 }

type region struct{ count, qty, revenue int64 }

type part struct {
	rows    int64
	regions map[[2]byte]*region
	users   map[int64]int64
	skus    map[skuKey]int64
}

func parseInt(b []byte, i int) (int64, int) {
	var v int64
	for b[i] >= '0' && b[i] <= '9' {
		v = v*10 + int64(b[i]-'0')
		i++
	}
	return v, i + 1
}

func work(data []byte, p *part) {
	p.regions = make(map[[2]byte]*region, 32)
	p.users = make(map[int64]int64, 1<<20)
	p.skus = make(map[skuKey]int64, 1<<17)
	i, n := 0, len(data)
	for i < n {
		for data[i] != ',' {
			i++
		}
		i++
		user, j := parseInt(data, i)
		i = j
		var k skuKey
		for data[i] != ',' {
			if int(k.n) < skuMax {
				k.b[k.n] = data[i]
				k.n++
			}
			i++
		}
		i++
		qty, j := parseInt(data, i)
		price, j := parseInt(data, j)
		i = j
		code := [2]byte{data[i], data[i+1]}
		i += 3
		rev := qty * price
		r := p.regions[code]
		if r == nil {
			r = &region{}
			p.regions[code] = r
		}
		r.count++
		r.qty += qty
		r.revenue += rev
		p.rows++
		p.users[user] += rev
		p.skus[k] += rev
	}
}

func main() {
	f, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	st, _ := f.Stat()
	size := int(st.Size())
	var data []byte
	if size > 0 {
		data, err = syscall.Mmap(int(f.Fd()), 0, size, syscall.PROT_READ, syscall.MAP_PRIVATE)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	workers := runtime.GOMAXPROCS(0)
	if w, err := strconv.Atoi(os.Getenv("WORKERS")); err == nil && w > 0 {
		workers = w
		runtime.GOMAXPROCS(w)
	}
	if max := size/(1<<16) + 1; workers > max {
		workers = max
	}
	parts := make([]part, workers)
	var wg sync.WaitGroup
	start := 0
	for w := 0; w < workers; w++ {
		end := size
		if w < workers-1 {
			end = size / workers * (w + 1)
			if end < start {
				end = start
			}
			for end < size && data[end-1] != '\n' {
				end++
			}
		}
		wg.Add(1)
		go func(chunk []byte, p *part) {
			defer wg.Done()
			work(chunk, p)
		}(data[start:end], &parts[w])
		start = end
	}
	wg.Wait()

	// merge into the largest maps
	big := 0
	for w := range parts {
		if len(parts[w].users) > len(parts[big].users) {
			big = w
		}
	}
	rows := int64(0)
	regions := map[[2]byte]*region{}
	users := parts[big].users
	skus := parts[big].skus
	for w := range parts {
		p := &parts[w]
		rows += p.rows
		for code, r := range p.regions {
			t := regions[code]
			if t == nil {
				t = &region{}
				regions[code] = t
			}
			t.count += r.count
			t.qty += r.qty
			t.revenue += r.revenue
		}
		if w == big {
			continue
		}
		for u, v := range p.users {
			users[u] += v
		}
		for k, v := range p.skus {
			skus[k] += v
		}
		p.users, p.skus = nil, nil
	}

	type utop struct {
		user, rev int64
	}
	top := make([]utop, 0, 101)
	for u, v := range users {
		c := utop{u, v}
		if len(top) == 100 && !(c.rev > top[99].rev || (c.rev == top[99].rev && c.user < top[99].user)) {
			continue
		}
		at := len(top)
		if at < 100 {
			top = append(top, c)
		} else {
			at = 99
		}
		for at > 0 && (c.rev > top[at-1].rev || (c.rev == top[at-1].rev && c.user < top[at-1].user)) {
			top[at] = top[at-1]
			at--
		}
		top[at] = c
	}
	type stop struct {
		sku skuKey
		rev int64
	}
	stops := make([]stop, 0, len(skus))
	for k, v := range skus {
		stops = append(stops, stop{k, v})
	}
	sort.Slice(stops, func(a, b int) bool {
		if stops[a].rev != stops[b].rev {
			return stops[a].rev > stops[b].rev
		}
		return less(stops[a].sku, stops[b].sku)
	})

	codes := make([][2]byte, 0, len(regions))
	for c := range regions {
		codes = append(codes, c)
	}
	sort.Slice(codes, func(a, b int) bool { return string(codes[a][:]) < string(codes[b][:]) })

	out := bufio.NewWriterSize(os.Stdout, 1<<16)
	fmt.Fprintf(out, "rows=%d\n", rows)
	for _, c := range codes {
		r := regions[c]
		fmt.Fprintf(out, "region=%s count=%d qty=%d revenue=%d\n", string(c[:]), r.count, r.qty, r.revenue)
	}
	for i, t := range top {
		fmt.Fprintf(out, "top_user rank=%d user_id=%d revenue=%d\n", i+1, t.user, t.rev)
	}
	for i := 0; i < 10 && i < len(stops); i++ {
		fmt.Fprintf(out, "top_sku rank=%d sku=%s revenue=%d\n", i+1, stops[i].sku, stops[i].rev)
	}
	out.Flush()
}
