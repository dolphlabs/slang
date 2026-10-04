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

It also reports what share of requests, and of total waiting time, sits
above 1 / 10 / 100 / 1000 ms: a tail that is 0.3% of requests but 60% of
waiting time is a scheduling problem, not a throughput one.
