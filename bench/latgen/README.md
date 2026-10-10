# latgen

A keep-alive HTTP/1.1 load generator that records **every** request's
latency, for an exact distribution. Use it for anything about the tail.

`wrk`'s own latency figures are not safe for that on this runtime: in the
2026-09-29 run its reported average for slang was 31.6 ms where Little's
law (connections / throughput) caps the true mean at 2.6 ms, so its upper
percentiles overstate the tail. latgen prints that bound next to its own
mean as a self-check.

    go run bench/latgen/main.go -addr 127.0.0.1:8080 -c 200 -d 10s
    go run bench/latgen/main.go -addr 127.0.0.1:8080 -path /echo -body '{"message":"hi"}'
    go run bench/latgen/main.go -addr 127.0.0.1:8080 -path /api/quote -body-file quote_0.json
    go run bench/latgen/main.go ... -dump samples.csv   # conn,start_ns,latency_ns per request

For the PostgreSQL route diagnostic, set `PG_PROFILE=1` on the API server and
pass `-pg-profile` to latgen. The response headers then report pool acquisition
and client query, row-decoding, and connection-release times for each request:

    PG_PROFILE=1 ./api
    go run bench/latgen/main.go -addr 127.0.0.1:8080 -path /api/users/1 -c 64 -d 20s -pg-profile

This mode records the timing distribution. Compare the client query timings
with PostgreSQL's `pg_stat_statements` execution-time and call-count deltas to
separate server work from protocol, network, driver, and scheduler time.

Use `-expect-status` when a route has a known success code. Latgen reports
`bad_statuses` separately, so an HTTP 500 cannot inflate the completed-request
count while appearing to be a successful sample:

    go run bench/latgen/main.go ... -expect-status 201

It also reports what share of requests, and of total waiting time, sits
above 1 / 10 / 100 / 1000 ms: a tail that is 0.3% of requests but 60% of
waiting time is a scheduling problem, not a throughput one.
