// tcp_loadgen: a small, purpose-built raw-TCP load generator for
// stress-testing stress_test/programs/tcp_echo's echo server.
//
// Two modes:
//   - default (connection churn): each "request" is one connect ->
//     write -> read -> close round trip. Real, but bounded by the
//     OS's own ephemeral port range (macOS: ~16384 ports,
//     net.inet.ip.portrange.first/last) and TIME_WAIT duration --
//     sustained above roughly 10-15k connects/sec territory this
//     starts failing with "connect: can't assign requested address",
//     a CLIENT-side OS ceiling that has nothing to do with the
//     server under test (confirmed directly: it reproduces even at
//     concurrency=10, where server-side capacity obviously isn't the
//     constraint). Keep total -requests for this mode comfortably
//     under that ceiling.
//   - -persistent: each worker dials ONCE and does many sequential
//     echo round-trips on the same connection -- no reconnect churn,
//     so it scales to any -requests count. This is also the more
//     realistic shape for "how fast can this server echo bytes,
//     steady-state" as distinct from "how fast can it accept fresh
//     connections", which the churn mode measures instead.
//
// Usage:
//
//	go run tcp_loadgen.go -addr 127.0.0.1:9095 -concurrency 200 -requests 50000
//	go run tcp_loadgen.go -addr 127.0.0.1:9095 -concurrency 200 -requests 100000 -persistent
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type sample struct {
	latency time.Duration
	err     bool
	errMsg  string
}

func main() {
	addr := flag.String("addr", "127.0.0.1:9095", "tcp_echo server address")
	concurrency := flag.Int("concurrency", 50, "number of concurrent workers")
	duration := flag.Duration("duration", 60*time.Second, "safety-cap duration when -requests is set")
	requests := flag.Int("requests", 0, "stop after exactly this many total echo round-trips (0 = duration-based)")
	payloadSize := flag.Int("payload", 64, "payload size in bytes for each echo round-trip")
	timeout := flag.Duration("timeout", 5*time.Second, "per-round-trip timeout")
	outPath := flag.String("out", "", "path to write JSON results (default: stdout)")
	label := flag.String("label", "tcp_run", "label for this run, echoed in output")
	persistent := flag.Bool("persistent", false, "keep one connection per worker open and do many round-trips on it, instead of reconnecting every request")
	flag.Parse()

	payload := make([]byte, *payloadSize)
	for i := range payload {
		payload[i] = byte('a' + i%26)
	}

	results := make(chan sample, 65536)
	var wg sync.WaitGroup
	stop := make(chan struct{})
	var issued int64

	doOne := func() {
		start := time.Now()
		conn, err := net.DialTimeout("tcp", *addr, *timeout)
		if err != nil {
			results <- sample{err: true, errMsg: err.Error()}
			return
		}
		conn.SetDeadline(time.Now().Add(*timeout))
		if _, err := conn.Write(payload); err != nil {
			results <- sample{latency: time.Since(start), err: true}
			conn.Close()
			return
		}
		buf := make([]byte, len(payload))
		n := 0
		for n < len(buf) {
			m, err := conn.Read(buf[n:])
			if err != nil {
				results <- sample{latency: time.Since(start), err: true}
				conn.Close()
				return
			}
			n += m
		}
		lat := time.Since(start)
		conn.Close()
		ok := string(buf) == string(payload)
		results <- sample{latency: lat, err: !ok}
	}

	// One round-trip on an already-open connection -- no dial, no
	// close. Reuses the same conn across calls; a read/write error
	// signals the caller to give up on this connection (server closed
	// it, or something went wrong) rather than looping on a dead one.
	doOneOn := func(conn net.Conn) bool {
		start := time.Now()
		conn.SetDeadline(time.Now().Add(*timeout))
		if _, err := conn.Write(payload); err != nil {
			results <- sample{latency: time.Since(start), err: true, errMsg: err.Error()}
			return false
		}
		buf := make([]byte, len(payload))
		n := 0
		for n < len(buf) {
			m, err := conn.Read(buf[n:])
			if err != nil {
				results <- sample{latency: time.Since(start), err: true, errMsg: err.Error()}
				return false
			}
			n += m
		}
		lat := time.Since(start)
		ok := string(buf) == string(payload)
		results <- sample{latency: lat, err: !ok}
		return true
	}

	worker := func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			if *requests > 0 && atomic.AddInt64(&issued, 1) > int64(*requests) {
				return
			}
			doOne()
		}
	}

	persistentWorker := func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			conn, err := net.DialTimeout("tcp", *addr, *timeout)
			if err != nil {
				results <- sample{err: true, errMsg: err.Error()}
				return
			}
			// Ride this one connection until it errors, the request
			// budget runs out, or shutdown -- then move on (a fresh
			// worker loop iteration dials again only if there's still
			// budget left, which in practice means never for a clean
			// run: the server never closes a healthy connection).
			for {
				select {
				case <-stop:
					conn.Close()
					return
				default:
				}
				if *requests > 0 && atomic.AddInt64(&issued, 1) > int64(*requests) {
					conn.Close()
					return
				}
				if !doOneOn(conn) {
					break
				}
			}
			conn.Close()
		}
	}

	fmt.Fprintf(os.Stderr, "[%s] starting: addr=%s concurrency=%d duration=%s requests=%d payload=%dB persistent=%v\n",
		*label, *addr, *concurrency, *duration, *requests, *payloadSize, *persistent)

	wg.Add(*concurrency)
	for i := 0; i < *concurrency; i++ {
		if *persistent {
			go persistentWorker()
		} else {
			go worker()
		}
	}

	collected := make([]sample, 0, 1<<20)
	collectDone := make(chan struct{})
	go func() {
		for s := range results {
			collected = append(collected, s)
		}
		close(collectDone)
	}()

	runStart := time.Now()
	if *requests > 0 {
		deadline := runStart.Add(*duration)
		for atomic.LoadInt64(&issued) < int64(*requests) && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
		}
	} else {
		time.Sleep(*duration)
	}
	close(stop)
	wg.Wait()
	close(results)
	<-collectDone
	elapsed := time.Since(runStart)

	errCounts := map[string]int{}
	for _, s := range collected {
		if s.err && s.errMsg != "" {
			errCounts[s.errMsg]++
		}
	}
	if len(errCounts) > 0 {
		fmt.Fprintf(os.Stderr, "[%s] error breakdown:\n", *label)
		for msg, n := range errCounts {
			fmt.Fprintf(os.Stderr, "  %6d  %s\n", n, msg)
		}
	}

	report(*label, *addr, collected, elapsed, *concurrency, *payloadSize, *outPath)
}

type runReport struct {
	Label         string  `json:"label"`
	Addr          string  `json:"addr"`
	Concurrency   int     `json:"concurrency"`
	PayloadBytes  int     `json:"payload_bytes"`
	ElapsedSec    float64 `json:"elapsed_sec"`
	TotalCount    int     `json:"total_count"`
	TotalErrors   int     `json:"total_errors"`
	ThroughputRPS float64 `json:"throughput_rps"`
	MinMs         float64 `json:"min_ms"`
	MeanMs        float64 `json:"mean_ms"`
	P50Ms         float64 `json:"p50_ms"`
	P90Ms         float64 `json:"p90_ms"`
	P95Ms         float64 `json:"p95_ms"`
	P99Ms         float64 `json:"p99_ms"`
	MaxMs         float64 `json:"max_ms"`
}

func report(label, addr string, samples []sample, elapsed time.Duration, concurrency, payloadBytes int, outPath string) {
	lats := make([]float64, 0, len(samples))
	errs := 0
	for _, s := range samples {
		if s.err {
			errs++
		}
		lats = append(lats, float64(s.latency.Microseconds())/1000.0)
	}
	sort.Float64s(lats)
	pct := func(p float64) float64 {
		if len(lats) == 0 {
			return 0
		}
		idx := int(p * float64(len(lats)-1))
		return lats[idx]
	}
	sum := 0.0
	for _, v := range lats {
		sum += v
	}
	mean := 0.0
	if len(lats) > 0 {
		mean = sum / float64(len(lats))
	}
	min, max := 0.0, 0.0
	if len(lats) > 0 {
		min, max = lats[0], lats[len(lats)-1]
	}

	rr := runReport{
		Label: label, Addr: addr, Concurrency: concurrency, PayloadBytes: payloadBytes,
		ElapsedSec: elapsed.Seconds(), TotalCount: len(samples), TotalErrors: errs,
		ThroughputRPS: float64(len(samples)) / elapsed.Seconds(),
		MinMs:         min, MeanMs: mean,
		P50Ms: pct(0.50), P90Ms: pct(0.90), P95Ms: pct(0.95), P99Ms: pct(0.99), MaxMs: max,
	}

	out, _ := json.MarshalIndent(rr, "", "  ")
	if outPath == "" {
		fmt.Println(string(out))
		return
	}
	if err := os.WriteFile(outPath, out, 0644); err != nil {
		fmt.Fprintln(os.Stderr, "write output:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "[%s] done: %d round-trips, %d errors, %.1f req/s -> %s\n",
		label, rr.TotalCount, rr.TotalErrors, rr.ThroughputRPS, outPath)
}
