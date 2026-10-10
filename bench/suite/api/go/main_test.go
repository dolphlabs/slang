package main

import (
	"testing"

	"github.com/valyala/fasthttp"
)

func TestSetPGProfileHeaders(t *testing.T) {
	old := pgProfile
	defer func() { pgProfile = old }()

	var ctx fasthttp.RequestCtx
	pgProfile = true
	setPGProfile(&ctx, pgQueryProfile{poolAcquireNS: 1200, clientQueryNS: 3400})
	if got := string(ctx.Response.Header.Peek("X-Bench-PG-Pool-Acquire-Ns")); got != "1200" {
		t.Fatalf("pool acquire header = %q, want 1200", got)
	}
	if got := string(ctx.Response.Header.Peek("X-Bench-PG-Client-Query-Ns")); got != "3400" {
		t.Fatalf("client query header = %q, want 3400", got)
	}
	ctx.Response.Reset()
	pgProfile = false
	setPGProfile(&ctx, pgQueryProfile{poolAcquireNS: 1200, clientQueryNS: 3400})
	if got := ctx.Response.Header.Peek("X-Bench-PG-Pool-Acquire-Ns"); got != nil {
		t.Fatalf("profile header leaked with profiling disabled: %q", got)
	}
}
