#!/bin/sh
# Two builds of bench/map/main.sl against each other, in ABBA rounds,
# printing each mode's median ns_per_op per build.
#
#     sh bench/map/run.sh ./old-binary ./new-binary [rounds]
set -eu
a=$1; b=$2; rounds=${3:-6}
modes="str_hit str_miss str_long str_put str_del int_hit int_put"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/map-bench.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
run() { "$1" "$2" | sed 's/ns_per_op=\([0-9]*\).*/\1/' >>"$TMP/$3.$2"; }
for r in $(seq "$rounds"); do
    for m in $modes; do
        if [ $((r % 2)) -eq 1 ]; then run "$a" "$m" A; run "$b" "$m" B
        else run "$b" "$m" B; run "$a" "$m" A; fi
    done
done
med() { sort -n "$1" | awk '{v[NR]=$1} END {print (NR%2) ? v[(NR+1)/2] : int((v[NR/2]+v[NR/2+1])/2)}'; }
printf '%-9s %8s %8s %7s\n' mode A_ns B_ns B/A
for m in $modes; do
    x=$(med "$TMP/A.$m"); y=$(med "$TMP/B.$m")
    printf '%-9s %8s %8s %7s\n' "$m" "$x" "$y" "$(awk -v x="$x" -v y="$y" 'BEGIN { printf "%.2f", y / x }')"
done
