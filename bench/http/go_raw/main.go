package main

import (
	"net"
	"os"
	"runtime"
)

const response = "HTTP/1.0 200 OK\r\n" +
	"Content-Type: text/plain\r\n" +
	"Content-Length: 200\r\n" +
	"Connection: close\r\n" +
	"\r\n" +
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" +
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" +
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" +
	"01234567"

func serve(c net.Conn) {
	defer c.Close()
	buf := make([]byte, 2048)
	if _, err := c.Read(buf); err != nil {
		return
	}
	_, _ = c.Write([]byte(response))
}

func acceptLoop(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go serve(c)
	}
}

func main() {
	port := os.Getenv("HTTP_PORT")
	if port == "" {
		port = "18191"
	}
	ln, err := net.Listen("tcp", ":"+port)
	if err != nil {
		panic(err)
	}
	println("LISTEN_PORT " + port)
	n := runtime.GOMAXPROCS(0)
	if n < 1 {
		n = 1
	}
	for i := 1; i < n; i++ {
		go acceptLoop(ln)
	}
	acceptLoop(ln)
}
