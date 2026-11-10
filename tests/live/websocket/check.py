"""Fails unless every Autobahn case the slang agent ran was graded OK,
NON-STRICT, INFORMATIONAL or UNIMPLEMENTED (and its close OK or
INFORMATIONAL). UNIMPLEMENTED is the suite's grade for a negotiation the
client does not take part in: in 13.3-13.6 the server answers with
client_max_window_bits, which this client does not offer and so refuses,
as RFC 7692 requires.

    python3 tests/live/websocket/check.py /tmp/autobahn/clients/index.json
"""
import collections
import json
import sys

GOOD = {"OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED"}
GOOD_CLOSE = {"OK", "INFORMATIONAL"}

with open(sys.argv[1]) as f:
    index = json.load(f)
cases = index.get("slang")
if not cases:
    sys.exit("no results for agent slang")
grades = collections.Counter()
bad = []
for case, r in sorted(cases.items(), key=lambda kv: [int(x) for x in kv[0].split(".")]):
    grades[r["behavior"]] += 1
    if r["behavior"] not in GOOD or r["behaviorClose"] not in GOOD_CLOSE:
        bad.append("%s: %s / close %s" % (case, r["behavior"], r["behaviorClose"]))
print("%d cases: %s" % (len(cases), ", ".join("%s %d" % kv for kv in sorted(grades.items()))))
if bad:
    print("\n".join(bad))
    sys.exit(1)
