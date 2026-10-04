// latgen: keep-alive HTTP/1.1 load generator that records EVERY request's
// latency (no sampling, no histogram buckets), for an exact distribution.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type sample struct {
	start int64 // ns since test start
	lat   int64 // ns
}

func main() {
	addr := flag.String("addr", "127.0.0.1:18084", "host:port")
	path := flag.String("path", "/", "request path")
	body := flag.String("body", "", "POST body (empty = GET)")
	bodyFile := flag.String("body-file", "", "POST body read from this file (overrides -body)")
	c := flag.Int("c", 200, "connections")
	d := flag.Duration("d", 10*time.Second, "duration")
	timeout := flag.Duration("timeout", 5*time.Second, "per-request timeout")
	dump := flag.String("dump", "", "write start_ns,lat_ns per request to this file")
	flag.Parse()
	if *bodyFile != "" {
		b, err := os.ReadFile(*bodyFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "latgen:", err)
			os.Exit(1)
		}
		*body = string(b)
	}

	var req string
	if *body == "" {
		req = fmt.Sprintf("GET %s HTTP/1.1\r\nHost: bench\r\n\r\n", *path)
	} else {
		req = fmt.Sprintf("POST %s HTTP/1.1\r\nHost: bench\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", *path, len(*body), *body)
	}
	reqb := []byte(req)

	per := make([][]sample, *c)
	var timeouts, errs int
	var mu sync.Mutex
	var wg sync.WaitGroup
	t0 := time.Now()
	stop := t0.Add(*d)
	for i := 0; i < *c; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s := make([]sample, 0, 1<<16)
			var conn net.Conn
			var rd *bufio.Reader
			for time.Now().Before(stop) {
				if conn == nil {
					cn, err := net.DialTimeout("tcp", *addr, *timeout)
					if err != nil {
						mu.Lock()
						errs++
						mu.Unlock()
						time.Sleep(10 * time.Millisecond)
						continue
					}
					conn, rd = cn, bufio.NewReaderSize(cn, 16384)
				}
				st := time.Now()
				conn.SetDeadline(st.Add(*timeout))
				if _, err := conn.Write(reqb); err != nil {
					conn.Close()
					conn = nil
					mu.Lock()
					errs++
					mu.Unlock()
					continue
				}
				if err := readResponse(rd); err != nil {
					conn.Close()
					conn = nil
					mu.Lock()
					if ne, ok := err.(net.Error); ok && ne.Timeout() {
						timeouts++
					} else {
						errs++
					}
					mu.Unlock()
					continue
				}
				now := time.Now()
				s = append(s, sample{st.Sub(t0).Nanoseconds(), now.Sub(st).Nanoseconds()})
			}
			if conn != nil {
				conn.Close()
			}
			per[i] = s
		}(i)
	}
	wg.Wait()
	elapsed := time.Since(t0)

	var all []sample
	for _, s := range per {
		all = append(all, s...)
	}
	lats := make([]int64, len(all))
	var sum int64
	for i, s := range all {
		lats[i] = s.lat
		sum += s.lat
	}
	sort.Slice(lats, func(a, b int) bool { return lats[a] < lats[b] })
	n := len(lats)
	if n == 0 {
		fmt.Println("no responses")
		os.Exit(1)
	}
	pct := func(p float64) float64 { return float64(lats[int(p*float64(n-1))]) / 1e6 }
	rps := float64(n) / elapsed.Seconds()
	mean := float64(sum) / float64(n) / 1e6
	fmt.Printf("requests=%d rps=%.0f timeouts=%d errors=%d\n", n, rps, timeouts, errs)
	fmt.Printf("mean=%.3fms (littles-law bound c/rps=%.3fms)\n", mean, float64(*c)/rps*1e3)
	fmt.Printf("p50=%.3f p75=%.3f p90=%.3f p95=%.3f p99=%.3f p99.9=%.3f max=%.3f ms\n",
		pct(0.50), pct(0.75), pct(0.90), pct(0.95), pct(0.99), pct(0.999), float64(lats[n-1])/1e6)
	// share of requests / of total waiting time above thresholds
	for _, th := range []float64{1, 10, 100, 1000} {
		cnt, tsum := 0, int64(0)
		for _, l := range lats {
			if float64(l)/1e6 > th {
				cnt++
				tsum += l
			}
		}
		fmt.Printf("  >%gms: %.3f%% of requests, %.1f%% of all waiting time\n", th, 100*float64(cnt)/float64(n), 100*float64(tsum)/float64(sum))
	}
	if *dump != "" {
		f, _ := os.Create(*dump)
		w := bufio.NewWriter(f)
		for i, s := range per {
			for _, x := range s {
				fmt.Fprintf(w, "%d,%d,%d\n", i, x.start, x.lat)
			}
		}
		w.Flush()
		f.Close()
	}
}

func readResponse(rd *bufio.Reader) error {
	cl := -1
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" {
			break
		}
		if len(line) > 15 && strings.EqualFold(line[:15], "content-length:") {
			v, err := strconv.Atoi(strings.TrimSpace(line[15:]))
			if err != nil {
				return err
			}
			cl = v
		}
	}
	if cl < 0 {
		return fmt.Errorf("no content-length")
	}
	_, err := rd.Discard(cl)
	return err
}
