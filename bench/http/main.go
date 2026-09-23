// The real-server axis: net/http actually parsing each request, keep-
// alive left at its default (net/http reuses the connection unless a
// handler or client asks otherwise) -- see bench/http/README.md and
// bench/http/realserver/main.sl, its slang peer on this axis.
package main

import (
	"net/http"
	"os"
)

const body = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567"

func main() {
	port := os.Getenv("HTTP_PORT")
	if port == "" {
		port = "18181"
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte(body))
	})
	println("LISTEN_PORT " + port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		panic(err)
	}
}
