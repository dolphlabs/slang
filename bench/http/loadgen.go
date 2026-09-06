package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	rawURL := flag.String("url", "http://127.0.0.1:8080/", "target URL")
	c := flag.Int("c", 50, "concurrency")
	d := flag.Duration("d", 10*time.Second, "duration")
	timeout := flag.Duration("timeout", 5*time.Second, "per-request timeout")
	flag.Parse()

	hostport := strings.TrimPrefix(*rawURL, "http://")
	hostport = strings.TrimSuffix(hostport, "/")
	if i := strings.IndexByte(hostport, '/'); i >= 0 {
		hostport = hostport[:i]
	}

	req := []byte("GET / HTTP/1.0\r\nHost: bench\r\nConnection: close\r\n\r\n")
	lat := make([]time.Duration, 0, 1<<20)
	var mu sync.Mutex
	var okN, errN int64
	var wg sync.WaitGroup
	stop := time.Now().Add(*d)

	for i := 0; i < *c; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 1024)
			for time.Now().Before(stop) {
				t0 := time.Now()
				conn, err := net.DialTimeout("tcp", hostport, *timeout)
				if err != nil {
					atomic.AddInt64(&errN, 1)
					continue
				}
				conn.SetDeadline(time.Now().Add(*timeout))
				_, err = conn.Write(req)
				if err != nil {
					conn.Close()
					atomic.AddInt64(&errN, 1)
					continue
				}
				n, err := io.ReadFull(conn, buf[:1])
				if n > 0 {
					_, _ = io.Copy(io.Discard, conn)
				}
				conn.Close()
				dt := time.Since(t0)
				if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
					if n == 0 {
						atomic.AddInt64(&errN, 1)
						continue
					}
				}
				atomic.AddInt64(&okN, 1)
				mu.Lock()
				lat = append(lat, dt)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	p50 := time.Duration(0)
	p99 := time.Duration(0)
	if n := len(lat); n > 0 {
		p50 = lat[n*50/100]
		idx := n * 99 / 100
		if idx >= n {
			idx = n - 1
		}
		p99 = lat[idx]
	}
	secs := d.Seconds()
	rps := float64(okN) / secs
	fmt.Printf("RESULT rps=%.2f p50_ms=%.3f p99_ms=%.3f ok=%d errors=%d\n",
		rps, float64(p50.Microseconds())/1000.0, float64(p99.Microseconds())/1000.0,
		okN, errN)
	os.Exit(0)
}
