#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path

import pg_routes_report as report


class PGRouteReportTests(unittest.TestCase):
    def test_parses_status_and_profile_distributions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "latgen.log"
            path.write_text(
                "requests=42 rps=21 timeouts=0 errors=0 bad_statuses=0 expected_status=201\n"
                "p50=2.000 p75=2.200 p90=3.000 p95=3.200 p99=4.000 p99.9=5.000 max=6.000 ms\n"
                "PG_PROFILE responses=42 missing=0\n"
                "  pool_acquire us: mean=8.00 p50=4.00 p90=9.00 p99=12.00 max=20.00\n"
                "  client_query_row_decode_and_release us: mean=40.00 p50=30.00 p90=60.00 p99=90.00 max=100.00\n"
            )
            values, error = report.parse_latgen(path)
        self.assertIsNone(error)
        self.assertEqual(values["expected_status"], 201)
        self.assertEqual(values["p99_ms"], 4.0)
        self.assertEqual(values["pool_acquire"]["p99_us"], 12.0)

    def test_status_errors_invalidate_warmup(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "latgen.log"
            path.write_text(
                "requests=42 rps=21 timeouts=0 errors=0 bad_statuses=2 expected_status=200\n"
                "p50=2 p75=2 p90=3 p95=3 p99=4 p99.9=5 max=6 ms\n"
                "PG_PROFILE responses=42 missing=0\n"
            )
            self.assertEqual(report.check_log(path, 200), 1)

    def test_sql_call_count_and_process_caps_validate_a_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "meta.json").write_text(json.dumps({
                "route": "point", "concurrency": 64, "round": 1, "position": 1,
                "language": "slang", "expected_status": 200, "latgen_exit": 0,
                "cpu_steal_pct": 0.0,
            }))
            (directory / "latgen.log").write_text(
                "requests=42 rps=21 timeouts=0 errors=0 bad_statuses=0 expected_status=200\n"
                "p50=2 p75=2 p90=3 p95=3 p99=4 p99.9=5 max=6 ms\n"
                "PG_PROFILE responses=42 missing=0\n"
                "  pool_acquire us: mean=8.00 p50=4.00 p90=9.00 p99=12.00 max=20.00\n"
                "  client_query_row_decode_and_release us: mean=40.00 p50=30.00 p90=60.00 p99=90.00 max=100.00\n"
            )
            header = "queryid\tcalls\trows\ttotal_exec_time\tmean_exec_time\tquery\n"
            (directory / "pg-before.tsv").write_text(header)
            (directory / "pg-after.tsv").write_text(header + "123\t42\t42\t8.4\t0.2\tSELECT 1\n")
            for name, cpu in (("api-sampler.json", 1.0), ("postgres-sampler.json", 0.4), ("loadgen-sampler.json", 0.5)):
                (directory / name).write_text(json.dumps({"avg_cpu_cores": cpu, "peak_rss_kb": 1000}))
            result = report.load_metrics(directory, 0.95, 2.0)
        self.assertTrue(result["metrics"]["valid"])
        self.assertEqual(result["metrics"]["postgres"]["calls"], 42)

    def test_report_keeps_the_route_gate_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "raw" / "point" / "c64").mkdir(parents=True)
            (root / "env.json").write_text(json.dumps({
                "run_id": "sample", "git_sha": "abc", "git_dirty": False,
                "seed": {"users": 20_000, "orders": 400_000},
                "database": {"server_version_num": 160000, "pool_size": 64},
                "toolchains": {"go": "go1.24.1"},
                "host": {"postgres_cpus": "0,1,2", "loadgen_cpu": 3, "memory_total_kb": 16_000_000},
                "matrix": {"routes": ["point"], "concurrencies": [64], "rounds": 1},
            }))
            for lang, rps in (("slang", 98.0), ("go", 100.0)):
                for position in (1, 2):
                    directory = root / "raw" / "point" / "c64" / f"{lang}-{position}"
                    directory.mkdir()
                    (directory / "meta.json").write_text(json.dumps({
                        "route": "point", "concurrency": 64, "round": 1, "position": position,
                        "language": lang, "metrics": {"valid": True, "invalid_reasons": [],
                            "latgen": {"rps": rps, "p99_ms": 2.0},
                            "pool_acquire": {"p99_us": 3.0},
                            "client_query_row_decode_and_release": {"p99_us": 4.0},
                            "postgres": {"mean_exec_ms": 0.1},
                            "api": {"avg_cpu_cores": 0.5, "peak_rss_kb": 1024},
                            "loadgen": {"avg_cpu_cores": 0.4},
                        },
                    }))
            self.assertEqual(report.report(root, 0.95, 2.0), 0)
            summary = (root / "summary.md").read_text()
            self.assertIn("| point | 64 | 98 / 100 | 98.0% |", summary)
            self.assertIn("| PASS |", summary)


if __name__ == "__main__":
    unittest.main()
