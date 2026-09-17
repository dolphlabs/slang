# Benchmark run 20260917T203432Z-cursor-scaled20

- commit `0fad8dcc9bf191519fe3a15b1eb6e56ef8715aab` (dirty tree)
- Ubuntu 24.04.4 LTS, kernel 6.12.94+, 4 cpus, 15Gi RAM
- cpu split: server `0-1` (2 workers), load generator `2-2`, database `3-3`
- rounds: 3; medians shown

**Failed and not measured:** java (api)

## api / mix — 512 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| go | 24,089 | 23.15 | 37.22 | — | 0.00% | 190.9 | 1.60 | 0.94 |

## api / mix — 64 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| go | 24,906 | 2.44 | 7.62 | — | 0.00% | 66.1 | 1.69 | 0.92 |

## api / point — 512 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| go | 32,442 | 15.50 | 23.07 | — | 0.00% | 85.7 | 1.13 | 0.98 |

## api / point — 64 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| go | 33,038 | 1.88 | 4.30 | — | 0.00% | 189.1 | 1.09 | 0.98 |

## compute

| lang | wall ms | tasks/s | peak RSS MB | CPU s |
|---|---|---|---|---|
| c | 1,449 | 690 | 8.7 | 2.8 |
| rust | 1,498 | 667 | 10.1 | 2.7 |
| slang | 1,757 | 569 | 13.3 | 3.2 |
| bun | 1,785 | 560 | 88.4 | 3.2 |
| node | 1,801 | 555 | 81.1 | 3.6 |
| java | 1,990 | 502 | 72.5 | 3.7 |
| csharp | 2,072 | 482 | 41.7 | 3.6 |
| go | 2,637 | 379 | 8.3 | 5.2 |
| python | 28,191 | 35 | 36.6 | 56.2 |

## http / static — 200 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores |
|---|---|---|---|---|---|---|---|
| bun | 38,117 | 1.30 | 4.65 | — | 0.00% | 238.3 | 0.88 |
| rust | 37,595 | 1.00 | 3.68 | — | 0.00% | 3.6 | 1.16 |
| c | 37,267 | 0.96 | 3.62 | — | 0.00% | 1.8 | 0.59 |
| python | 37,073 | 0.96 | 3.60 | — | 0.00% | 55.0 | 0.74 |
| java | 37,017 | 1.16 | 4.13 | — | 0.00% | 124.3 | 1.29 |
| go | 36,492 | 1.13 | 4.13 | — | 0.00% | 9.8 | 1.09 |
| slang | 35,553 | 1.31 | 4.44 | — | 0.00% | 4.2 | 1.04 |
| csharp | 35,305 | 1.20 | 4.35 | — | 0.00% | 40.8 | 1.78 |
| node | 29,541 | 6.66 | 9.28 | — | 0.00% | 205.5 | 1.60 |

## http / static — 50 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores |
|---|---|---|---|---|---|---|---|
| slang | 39,856 | 0.33 | 1.01 | — | 0.00% | 2.9 | 1.03 |
| python | 39,062 | 0.24 | 0.92 | — | 0.00% | 54.5 | 0.79 |
| java | 38,942 | 0.35 | 1.14 | — | 0.00% | 125.6 | 1.30 |
| go | 38,439 | 0.30 | 1.06 | — | 0.00% | 9.6 | 1.12 |
| bun | 38,043 | 0.27 | 1.19 | — | 0.00% | 146.0 | 0.73 |
| c | 38,034 | 0.24 | 0.95 | — | 0.00% | 1.8 | 0.62 |
| rust | 38,021 | 0.26 | 0.97 | — | 0.00% | 3.2 | 1.22 |
| csharp | 33,030 | 0.31 | 1.16 | — | 0.00% | 40.0 | 1.86 |
| node | 29,190 | 1.60 | 4.26 | — | 0.00% | 184.6 | 1.64 |

