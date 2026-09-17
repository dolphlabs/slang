# Benchmark run 20260917T202348Z-cursor

- commit `94399c027b4043a599161ccf1287dac90ddafc56` (dirty tree)
- Ubuntu 24.04.4 LTS, kernel 6.12.94+, 4 cpus, 15Gi RAM
- cpu split: server `0-1` (2 workers), load generator `2-2`, database `3-3`
- rounds: 1; medians shown

**Failed and not measured:** none

## api / mix — 512 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 15,398 | 35.62 | 62.09 | — | 0.00% | 185.4 | 1.93 | 0.57 |

## api / mix — 64 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 10,515 | 5.16 | 22.99 | — | 0.00% | 137.7 | 1.91 | 0.47 |

## api / mix — fixed 10000/s (wrk2)

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 9,373 | 2.24 | 61.25 | 81.15 | 0.00% | 198.3 | 1.39 | — |

## api / mix — fixed 2000/s (wrk2)

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 1,885 | 1.29 | 3.53 | 15.17 | 0.00% | 191.0 | 0.55 | — |

## api / point — 512 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 35,439 | 14.16 | 19.13 | — | 0.00% | 187.0 | 1.87 | 0.94 |

## api / point — 64 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 39,433 | 1.58 | 3.43 | — | 0.00% | 163.0 | 1.92 | 0.95 |

## api / quote — 512 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 2,582 | 191.36 | 314.65 | — | 0.00% | 199.1 | 1.91 | 0.00 |

## api / quote — 64 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores | DB CPU |
|---|---|---|---|---|---|---|---|---|
| csharp | 2,739 | 22.91 | 41.88 | — | 0.00% | 162.7 | 1.91 | 0.00 |

## batch

| lang | wall s | peak RSS MB | CPU s | output agrees |
|---|---|---|---|---|
| csharp | 0.44 | 131.8 | 0.7 | yes |

## compute

| lang | wall ms | tasks/s | peak RSS MB | CPU s |
|---|---|---|---|---|
| csharp | 203 | 985 | 31.2 | 0.2 |

## http / static — 200 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores |
|---|---|---|---|---|---|---|---|
| csharp | 33,924 | 1.26 | 4.78 | — | 0.00% | 40.5 | 1.71 |

## http / static — 50 connections

| lang | req/s | p50 ms | p99 ms | p99.9 ms | errors | peak RSS MB | CPU cores |
|---|---|---|---|---|---|---|---|
| csharp | 34,637 | 0.33 | 2.13 | — | 0.00% | 39.8 | 1.76 |

