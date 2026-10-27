#!/usr/bin/env bash
# The sort package against Go's on this host: ABBA ordering (slang, go,
# go, slang) per round, medians per scene across all runs, and each
# binary's peak RSS from /usr/bin/time -l. Builds nothing outside
# bench/sort/.build/ (which .gitignore covers via `main`/`main2` only --
# this directory is local scratch, never committed).
#
#     bench/sort/run.sh              # three ABBA rounds, about a minute
#     ROUNDS=5 bench/sort/run.sh     # more rounds for tighter medians
#
# Units note: /usr/bin/time -l reports maximum resident set size in
# BYTES on macOS and in KB on Linux; the raw number is printed either
# way, and README.md records which host produced the table.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT/bench/sort"
ROUNDS=${ROUNDS:-3}

# ---- build -----------------------------------------------------------

rm -rf .build
mkdir -p .build/runs .build/sl .build/go_src
cp main.sl .build/sl/main.sl
cp go/main.go go/go.mod .build/go_src/

(cd .build/sl && "$ROOT/slangc" main.sl) || exit 1
mv .build/sl/main .build/sort_slang
(cd .build/go_src && go build -o ../sort_go .) || exit 1
echo "built both"

# ---- ABBA rounds ---------------------------------------------------

for r in $(seq 1 "$ROUNDS"); do
    .build/sort_slang > .build/runs/slang_r${r}.log
    .build/sort_go    > .build/runs/go_r${r}.log
    .build/sort_go    > .build/runs/go_r${r}b.log
    .build/sort_slang > .build/runs/slang_r${r}b.log
done

# ---- medians per scene, both languages ------------------------------
# Raw logs stay in .build/runs/ for anyone who wants to re-aggregate.

python3 - <<'PY'
import pathlib, statistics

by = {}
for p in sorted(pathlib.Path(".build/runs").glob("*.log")):
    lang = p.name.split("_r")[0]
    for line in p.read_text().splitlines():
        parts = line.split(",")
        if len(parts) == 4 and parts[0] == "scene":
            by.setdefault((lang, parts[1]), []).append(float(parts[3]))

scenes = sorted({s for _, s in by})
print("%-24s%12s%10s%10s" % ("scene", "slang ms", "go ms", "slang/go"))
for s in scenes:
    sl = statistics.median(by.get(("slang", s), [float("nan")]))
    go = statistics.median(by.get(("go", s), [float("nan")]))
    print("%-24s%12.2f%10.2f%10.2f" % (s, sl, go, sl / go))
PY

# ---- peak RSS -------------------------------------------------------

echo
for lang in slang go; do
    rss=$({ /usr/bin/time -l ".build/sort_${lang}" > /dev/null; } 2>&1 \
          | grep -i 'maximum res' \
          | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]/) { print $i; exit } }')
    echo "peak RSS ($lang): ${rss:-(no /usr/bin/time -l on this host)}"
done
