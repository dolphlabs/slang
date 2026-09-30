"""A test double for the runner (run.py selftest): reads the prompt as an
agent would, "builds" the task by copying its reference server into the
work directory, writes start.sh, and prints a usage report in Claude
Code's shape. It proves the harness end to end without spending tokens."""

import json
import re
import shutil
import sys
from pathlib import Path

prompt = sys.stdin.read()
m = re.search(r"^# Task: ([a-z]+)", prompt, re.M)
if not m:
    sys.exit("fake agent: no task in the prompt")
here = Path(__file__).resolve().parent
for f in ("base.py", m.group(1) + ".py"):
    shutil.copy(here / f, f)
Path("start.sh").write_text("exec python3 %s.py\n" % m.group(1))
print(json.dumps({"usage": {"input_tokens": 1000, "cache_read_input_tokens": 500,
                            "output_tokens": 200},
                  "num_turns": 7, "total_cost_usd": 0.05}))
