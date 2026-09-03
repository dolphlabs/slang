// loadgen: a small, purpose-built HTTP load generator for stress-testing
// the slang Arcade demo server. Not part of the slang project itself --
// this is throwaway Go tooling that drives load against /api/stress/*
// endpoints and reports latency percentiles, throughput, and error rates.
//
// Usage:
//
//	go run loadgen.go -config scenario.json -concurrency 500 -duration 20s
//
// scenario.json:
//
//	{
//	  "base_url": "http://localhost:8090",
//	  "requests": [
//	    {"name": "ping",    "method": "GET",  "path": "/api/stress/ping", "weight": 1},
//	    {"name": "cpu",     "method": "POST", "path": "/api/stress/cpu",  "weight": 1, "body": "{\"n\":20000}"}
//	  ]
//	}
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type ReqSpec struct {
	Name   string `json:"name"`
	Method string `json:"method"`
	Path   string `json:"path"`
	Body   string `json:"body"`
	Weight int    `json:"weight"`
}

type Scenario struct {
	BaseURL  string    `json:"base_url"`
	Requests []ReqSpec `json:"requests"`
}

type sample struct {
	name    string
	latency time.Duration
	status  int
	err     bool
}

func main() {
	configPath := flag.String("config", "", "path to scenario JSON")
	concurrency := flag.Int("concurrency", 50, "number of concurrent workers")
	duration := flag.Duration("duration", 10*time.Second, "how long to run (safety cap when -requests is set; exact stop condition otherwise)")
	requests := flag.Int("requests", 0, "stop after exactly this many total requests (0 = duration-based instead)")
	ratePerSec := flag.Int("rate", 0, "target total requests/sec across all workers (0 = closed-loop, workers hammer as fast as possible)")
	timeout := flag.Duration("timeout", 10*time.Second, "per-request timeout")
	outPath := flag.String("out", "", "path to write JSON results (default: stdout)")
	label := flag.String("label", "run", "label for this run, echoed in output")
	flag.Parse()

	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "usage: loadgen -config scenario.json [flags]")
		os.Exit(2)
	}
	raw, err := os.ReadFile(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read config:", err)
		os.Exit(1)
	}
	var sc Scenario
	if err := json.Unmarshal(raw, &sc); err != nil {
		fmt.Fprintln(os.Stderr, "parse config:", err)
		os.Exit(1)
	}
	if len(sc.Requests) == 0 {
		fmt.Fprintln(os.Stderr, "scenario has no requests")
		os.Exit(1)
	}

	totalWeight := 0
	for _, r := range sc.Requests {
		if r.Weight <= 0 {
			r.Weight = 1
		}
		totalWeight += r.Weight
	}
	picker := make([]ReqSpec, 0, totalWeight)
	for _, r := range sc.Requests {
		w := r.Weight
		if w <= 0 {
			w = 1
		}
		for i := 0; i < w; i++ {
			picker = append(picker, r)
		}
	}

	client := &http.Client{
		Timeout: *timeout,
		Transport: &http.Transport{
			DisableKeepAlives:  true, // server sends Connection: close anyway; be honest about it
			MaxIdleConnsPerHost: -1,
			DisableCompression: true,
		},
	}

	results := make(chan sample, 65536)
	var wg sync.WaitGroup
	stop := make(chan struct{})
	var issued int64

	doOne := func(rng *rand.Rand) {
		spec := picker[rng.Intn(len(picker))]
		url := sc.BaseURL + spec.Path
		var bodyReader io.Reader
		if spec.Body != "" {
			bodyReader = bytes.NewReader([]byte(spec.Body))
		}
		req, err := http.NewRequest(spec.Method, url, bodyReader)
		if err != nil {
			results <- sample{name: spec.Name, err: true}
			return
		}
		if spec.Body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		start := time.Now()
		resp, err := client.Do(req)
		lat := time.Since(start)
		if err != nil {
			results <- sample{name: spec.Name, latency: lat, err: true}
			return
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		results <- sample{name: spec.Name, latency: lat, status: resp.StatusCode, err: resp.StatusCode >= 400}
	}

	worker := func(seed int64) {
		defer wg.Done()
		rng := rand.New(rand.NewSource(seed))
		for {
			select {
			case <-stop:
				return
			default:
			}
			if *requests > 0 && atomic.AddInt64(&issued, 1) > int64(*requests) {
				return
			}
			doOne(rng)
		}
	}

	rateWorker := func(seed int64, perWorkerRate float64) {
		defer wg.Done()
		rng := rand.New(rand.NewSource(seed))
		if perWorkerRate <= 0 {
			return
		}
		interval := time.Duration(float64(time.Second) / perWorkerRate)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				atomic.AddInt64(&issued, 1)
				doOne(rng)
			}
		}
	}

	fmt.Fprintf(os.Stderr, "[%s] starting: concurrency=%d duration=%s requests=%d rate=%d req/s target=%s\n",
		*label, *concurrency, *duration, *requests, *ratePerSec, sc.BaseURL)

	wg.Add(*concurrency)
	if *ratePerSec > 0 {
		perWorker := float64(*ratePerSec) / float64(*concurrency)
		for i := 0; i < *concurrency; i++ {
			go rateWorker(int64(i)+1, perWorker)
		}
	} else {
		for i := 0; i < *concurrency; i++ {
			go worker(int64(i) + 1)
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
		// Exact-count mode: poll until enough requests have been issued
		// (or the duration cap trips as a safety net against a stalled
		// server never letting workers finish issuing), rather than a
		// plain sleep -- the whole point is stopping at a precise count,
		// not a precise wall-clock duration.
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

	report(*label, sc, collected, elapsed, *concurrency, *ratePerSec, *outPath)
}

type endpointStats struct {
	Name       string  `json:"name"`
	Count      int     `json:"count"`
	Errors     int     `json:"errors"`
	ErrorRate  float64 `json:"error_rate"`
	ThroughputRPS float64 `json:"throughput_rps"`
	MinMs      float64 `json:"min_ms"`
	MeanMs     float64 `json:"mean_ms"`
	P50Ms      float64 `json:"p50_ms"`
	P90Ms      float64 `json:"p90_ms"`
	P95Ms      float64 `json:"p95_ms"`
	P99Ms      float64 `json:"p99_ms"`
	P999Ms     float64 `json:"p999_ms"`
	MaxMs      float64 `json:"max_ms"`
}

type runReport struct {
	Label       string          `json:"label"`
	BaseURL     string          `json:"base_url"`
	Concurrency int             `json:"concurrency"`
	RateTarget  int             `json:"rate_target"`
	ElapsedSec  float64         `json:"elapsed_sec"`
	TotalCount  int             `json:"total_count"`
	TotalErrors int             `json:"total_errors"`
	ThroughputRPS float64       `json:"throughput_rps"`
	Overall     endpointStats   `json:"overall"`
	ByEndpoint  []endpointStats `json:"by_endpoint"`
}

func statsFor(name string, samples []sample, elapsed time.Duration) endpointStats {
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
	return endpointStats{
		Name: name, Count: len(samples), Errors: errs,
		ErrorRate:     ratio(errs, len(samples)),
		ThroughputRPS: float64(len(samples)) / elapsed.Seconds(),
		MinMs:         min, MeanMs: mean,
		P50Ms: pct(0.50), P90Ms: pct(0.90), P95Ms: pct(0.95), P99Ms: pct(0.99), P999Ms: pct(0.999),
		MaxMs: max,
	}
}

func ratio(a, b int) float64 {
	if b == 0 {
		return 0
	}
	return float64(a) / float64(b)
}

func report(label string, sc Scenario, samples []sample, elapsed time.Duration, concurrency, rate int, outPath string) {
	byName := map[string][]sample{}
	for _, s := range samples {
		byName[s.name] = append(byName[s.name], s)
	}
	names := make([]string, 0, len(byName))
	for n := range byName {
		names = append(names, n)
	}
	sort.Strings(names)

	rr := runReport{
		Label: label, BaseURL: sc.BaseURL, Concurrency: concurrency, RateTarget: rate,
		ElapsedSec: elapsed.Seconds(), TotalCount: len(samples),
		ThroughputRPS: float64(len(samples)) / elapsed.Seconds(),
		Overall:       statsFor("overall", samples, elapsed),
	}
	for _, n := range names {
		es := statsFor(n, byName[n], elapsed)
		rr.ByEndpoint = append(rr.ByEndpoint, es)
		rr.TotalErrors += es.Errors
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
	fmt.Fprintf(os.Stderr, "[%s] done: %d requests, %d errors, %.1f req/s -> %s\n",
		label, rr.TotalCount, rr.TotalErrors, rr.ThroughputRPS, outPath)
}
