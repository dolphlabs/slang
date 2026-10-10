package main

import (
	"bufio"
	"strings"
	"testing"
)

func TestReadResponseStatusAndPGProfile(t *testing.T) {
	response := "HTTP/1.1 201 Created\r\n" +
		"Content-Length: 2\r\n" +
		"X-Bench-PG-Pool-Acquire-Ns: 17\r\n" +
		"X-Bench-PG-Client-Query-Ns: 29\r\n\r\n{}"
	status, profile, err := readResponse(bufio.NewReader(strings.NewReader(response)), true)
	if err != nil {
		t.Fatal(err)
	}
	if status != 201 {
		t.Fatalf("status = %d, want 201", status)
	}
	if !profile.valid || profile.poolAcquireNS != 17 || profile.clientQueryNS != 29 {
		t.Fatalf("profile = %+v, want valid 17/29 ns", profile)
	}
}

func TestReadResponseRejectsMalformedStatus(t *testing.T) {
	_, _, err := readResponse(bufio.NewReader(strings.NewReader("not HTTP\r\n\r\n")), false)
	if err == nil {
		t.Fatal("malformed status line was accepted")
	}
}
