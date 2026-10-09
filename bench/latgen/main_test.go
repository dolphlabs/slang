package main

import (
	"bufio"
	"strings"
	"testing"
)

func TestReadResponsePGProfile(t *testing.T) {
	response := "HTTP/1.1 200 OK\r\n" +
		"Content-Length: 2\r\n" +
		"x-bench-pg-pool-acquire-ns: 1200\r\n" +
		"X-Bench-PG-Client-Query-Ns: 3400\r\n\r\n{}"
	got, err := readResponse(bufio.NewReader(strings.NewReader(response)), true)
	if err != nil {
		t.Fatal(err)
	}
	if !got.valid || got.poolAcquireNS != 1200 || got.clientQueryNS != 3400 {
		t.Fatalf("unexpected profile: %+v", got)
	}
}

func TestReadResponsePGProfileMissingHeaders(t *testing.T) {
	response := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
	got, err := readResponse(bufio.NewReader(strings.NewReader(response)), true)
	if err != nil {
		t.Fatal(err)
	}
	if got.valid {
		t.Fatalf("profile without timing headers marked valid: %+v", got)
	}
}

func TestReadResponsePGProfileRejectsDuplicateTimingHeader(t *testing.T) {
	response := "HTTP/1.1 200 OK\r\n" +
		"Content-Length: 2\r\n" +
		"X-Bench-PG-Pool-Acquire-Ns: 1200\r\n" +
		"X-Bench-PG-Pool-Acquire-Ns: 1300\r\n" +
		"X-Bench-PG-Client-Query-Ns: 3400\r\n\r\n{}"
	if _, err := readResponse(bufio.NewReader(strings.NewReader(response)), true); err == nil {
		t.Fatal("duplicate profile header accepted")
	}
}
