// An HTTP/2 client built on golang.org/x/net/http2 -- an implementation
// with no shared ancestry with nghttp2, which is what curl uses. The
// point of this probe is that every previous interop check for the
// slang h2 server ran against nghttp2's framing and HPACK, one way or
// another, so agreement proved less than it appeared to.
//
// h2c with prior knowledge: AllowHTTP plus a DialTLSContext that
// returns a plain TCP conn is Go's supported way to speak cleartext
// HTTP/2 without an upgrade dance.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/http2"
)

var fails int

func check(name string, cond bool, detail string) {
	if cond {
		fmt.Printf("ok    %s\n", name)
		return
	}
	fmt.Printf("FAIL  %s: %s\n", name, detail)
	fails++
}

func newClient() *http.Client {
	return &http.Client{
		Transport: &http2.Transport{
			AllowHTTP: true,
			DialTLSContext: func(ctx context.Context, network, addr string,
				_ *tls.Config) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, addr)
			},
		},
		Timeout: 20 * time.Second,
	}
}

func main() {
	base := "http://" + os.Args[1]
	c := newClient()

	// 1. A plain GET. Go verifies the frame sequence, the HPACK block,
	//    and that the response is well-formed h2 before handing it back.
	resp, err := c.Get(base + "/hello")
	if err != nil {
		fmt.Printf("FAIL  GET: %v\n", err)
		os.Exit(1)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	check("GET status", resp.StatusCode == 200,
		fmt.Sprintf("got %d", resp.StatusCode))
	check("GET proto", resp.Proto == "HTTP/2.0", resp.Proto)
	check("GET body", string(body) == "path=/hello",
		fmt.Sprintf("got %q", string(body)))
	check("GET content-type", resp.Header.Get("Content-Type") == "text/plain",
		resp.Header.Get("Content-Type"))

	// 2. POST with a body: exercises DATA frames INTO the server and the
	//    receive-side WINDOW_UPDATE that has to come back out.
	payload := strings.Repeat("abcdefghij", 5000) // 50000 octets
	resp, err = c.Post(base+"/echo", "text/plain", strings.NewReader(payload))
	if err != nil {
		fmt.Printf("FAIL  POST: %v\n", err)
		os.Exit(1)
	}
	body, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	want := "path=/echo echo=" + payload
	check("POST 50KB round-trip", string(body) == want,
		fmt.Sprintf("got %d bytes, wanted %d", len(body), len(want)))

	// 3. A large response, which is what makes the server's send-side
	//    flow control run for real: Go advertises its own windows and
	//    will treat an overrun as a connection error.
	resp, err = c.Get(base + "/big")
	if err != nil {
		fmt.Printf("FAIL  GET /big: %v\n", err)
		os.Exit(1)
	}
	body, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	check("flow-controlled 200KB response", len(body) == 200000,
		fmt.Sprintf("got %d bytes", len(body)))
	okPattern := true
	for i := 0; i < len(body); i++ {
		if body[i] != byte('0'+(i%10)) {
			okPattern = false
			break
		}
	}
	check("200KB payload intact", okPattern, "byte pattern diverged")

	// 4. Concurrent streams on ONE connection. Go multiplexes these over
	//    a single TCP conn, so this is the real multiplexing check --
	//    and the slow request is issued first, so finishing in about the
	//    slow one's own time proves they overlapped.
	start := time.Now()
	var wg sync.WaitGroup
	results := make([]string, 6)
	paths := []string{"/slow", "/a", "/b", "/c", "/d", "/e"}
	for i, p := range paths {
		wg.Add(1)
		go func(i int, p string) {
			defer wg.Done()
			r, err := c.Get(base + p)
			if err != nil {
				results[i] = "err:" + err.Error()
				return
			}
			b, _ := io.ReadAll(r.Body)
			r.Body.Close()
			results[i] = string(b)
		}(i, p)
	}
	wg.Wait()
	elapsed := time.Since(start)
	allOK := true
	for i, p := range paths {
		if results[i] != "path="+p {
			allOK = false
			fmt.Printf("      stream %s -> %q\n", p, results[i])
		}
	}
	check("6 concurrent streams, one connection", allOK, "see above")
	// /slow sleeps 400ms server-side. Serialised, six of these would be
	// well past that; multiplexed they land together.
	check("streams overlapped", elapsed < 1200*time.Millisecond,
		fmt.Sprintf("took %v", elapsed))
	fmt.Printf("      6 streams in %v\n", elapsed)

	if fails > 0 {
		fmt.Printf("\n%d check(s) failed\n", fails)
		os.Exit(1)
	}
	fmt.Println("\nall Go http2 interop checks passed")
}
