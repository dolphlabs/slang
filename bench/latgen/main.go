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

type pgProfileSample struct {
	poolAcquireNS int64
	clientQueryNS int64
	valid         bool
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
	pgProfile := flag.Bool("pg-profile", false, "collect X-Bench-PG-* response headers")
	expectStatus := flag.Int("expect-status", 0, "count responses with another status as bad (0 disables)")
	flag.Parse()
	if *expectStatus < 0 || *expectStatus > 599 || (*expectStatus > 0 && *expectStatus < 100) {
		fmt.Fprintln(os.Stderr, "latgen: -expect-status must be 0 or an HTTP status from 100 to 599")
		os.Exit(2)
	}
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
	var perPGProfile [][]pgProfileSample
	if *pgProfile {
		perPGProfile = make([][]pgProfileSample, *c)
	}
	var timeouts, errs, badStatuses int
	var mu sync.Mutex
	var wg sync.WaitGroup
	t0 := time.Now()
	stop := t0.Add(*d)
	for i := 0; i < *c; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s := make([]sample, 0, 1<<16)
			var pgSamples []pgProfileSample
			if *pgProfile {
				pgSamples = make([]pgProfileSample, 0, 1024)
			}
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
				status, profile, err := readResponse(rd, *pgProfile)
				if err != nil {
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
				if *expectStatus != 0 && status != *expectStatus {
					mu.Lock()
					badStatuses++
					mu.Unlock()
				}
				if *pgProfile {
					pgSamples = append(pgSamples, profile)
				}
			}
			if conn != nil {
				conn.Close()
			}
			per[i] = s
			if *pgProfile {
				perPGProfile[i] = pgSamples
			}
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
	fmt.Printf("requests=%d rps=%.0f timeouts=%d errors=%d bad_statuses=%d expected_status=%d\n",
		n, rps, timeouts, errs, badStatuses, *expectStatus)
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
	if *pgProfile {
		var profiles []pgProfileSample
		for _, s := range perPGProfile {
			profiles = append(profiles, s...)
		}
		printPGProfile(profiles)
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

func readResponse(rd *bufio.Reader, wantPGProfile bool) (int, pgProfileSample, error) {
	var profile pgProfileSample
	seen := 0
	cl := -1
	status := 0
	line, err := rd.ReadString('\n')
	if err != nil {
		return status, profile, err
	}
	fields := strings.Fields(line)
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/") {
		return status, profile, fmt.Errorf("invalid HTTP status line %q", strings.TrimSpace(line))
	}
	status, err = strconv.Atoi(fields[1])
	if err != nil || status < 100 || status > 599 {
		return 0, profile, fmt.Errorf("invalid HTTP status code in %q", strings.TrimSpace(line))
	}
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			return status, profile, err
		}
		if line == "\r\n" {
			break
		}
		if len(line) > 15 && strings.EqualFold(line[:15], "content-length:") {
			v, err := strconv.Atoi(strings.TrimSpace(line[15:]))
			if err != nil {
				return status, profile, err
			}
			cl = v
		} else if wantPGProfile {
			name, value, ok := strings.Cut(strings.TrimSpace(line), ":")
			if ok {
				value = strings.TrimSpace(value)
				switch {
				case strings.EqualFold(name, "X-Bench-PG-Pool-Acquire-Ns"):
					if seen&1 != 0 {
						return status, profile, fmt.Errorf("duplicate %s header", name)
					}
					profile.poolAcquireNS, err = strconv.ParseInt(value, 10, 64)
					seen |= 1
				case strings.EqualFold(name, "X-Bench-PG-Client-Query-Ns"):
					if seen&2 != 0 {
						return status, profile, fmt.Errorf("duplicate %s header", name)
					}
					profile.clientQueryNS, err = strconv.ParseInt(value, 10, 64)
					seen |= 2
				}
				if err != nil {
					return status, profile, fmt.Errorf("invalid %s header: %w", name, err)
				}
				if (seen&1 != 0 && profile.poolAcquireNS < 0) ||
					(seen&2 != 0 && profile.clientQueryNS < 0) {
					return status, profile, fmt.Errorf("negative %s header", name)
				}
			}
		}
	}
	if cl < 0 {
		return status, profile, fmt.Errorf("no content-length")
	}
	_, err = rd.Discard(cl)
	profile.valid = seen == 3
	return status, profile, err
}

func printPGProfile(profiles []pgProfileSample) {
	pool, query := make([]int64, 0, len(profiles)), make([]int64, 0, len(profiles))
	missing := 0
	for _, p := range profiles {
		if !p.valid {
			missing++
			continue
		}
		pool = append(pool, p.poolAcquireNS)
		query = append(query, p.clientQueryNS)
	}
	fmt.Printf("PG_PROFILE responses=%d missing=%d\n", len(profiles), missing)
	printPGDuration("pool_acquire", pool)
	printPGDuration("client_query_row_decode_and_release", query)
}

func printPGDuration(name string, values []int64) {
	if len(values) == 0 {
		fmt.Printf("  %s: no samples\n", name)
		return
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	var total int64
	for _, v := range values {
		total += v
	}
	percentile := func(p float64) float64 {
		return float64(values[int(p*float64(len(values)-1))]) / 1000
	}
	fmt.Printf("  %s us: mean=%.2f p50=%.2f p90=%.2f p99=%.2f max=%.2f\n",
		name, float64(total)/float64(len(values))/1000, percentile(.50), percentile(.90), percentile(.99), float64(values[len(values)-1])/1000)
}
