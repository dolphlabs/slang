// A value computed before a later sibling's call must be protected across
// that call, and the safepoint that protects it needs its type. It used
// to re-infer the value under the LATER sibling's expected type:
// `cells` below was typed against `label`'s opt[str], and `some(7)` was
// rejected with "cannot use int where str expected". The same held for
// call arguments. The loop makes collections land at those safepoints.

struct Row {
    cells: [opt[int]],
    label: opt[str],
}

fn name(n: int) -> str {
    return "row" + n;
}

fn width(cells: [opt[int]], label: opt[str]) -> int {
    return len(cells) + len(label ?? "");
}

let r = Row{cells: [some(7)], label: some(name(1))};
println(inspect(r.cells));
println(r.label ?? "-");
println(width([some(1), some(2)], some(name(22))));

let total = 0;
for i in 0..3000 {
    let row = Row{cells: [some(i), some(i + 1)], label: some(name(i))};
    total += len(row.cells) + len(row.label ?? "");
    total += width([some(i)], some(name(i)));
}
println(total);
