// Lists and maps whose elements hold no GC pointer ([int], [float],
// enums, value structs of those) are never scanned by the collector
// (fix-gc.md 1.8). Containers that do hold pointers -- [str], a value
// struct with a str field, map[str]int -- sit beside them through many
// collections, and every value is checked at the end.
// tests/run_tests.sh also checks the generated C passes the pointer-free
// flag for the first kind.
import "strings";

struct Pt { x: int, y: int }
struct Tagged { name: str, n: int }
enum Color { red, green, blue }

let ints: [int] = [];
let flts: [float] = [];
let pts: [Pt] = [];
let colors: [Color] = [];
let counts: map[int]int = {};
let names: [str] = [];
let tagged: [Tagged] = [];
let byname: map[str]int = {};

let i = 0;
while i < 20000 {
    push(ints, i * 3);
    push(flts, (i as float) / 2.0);
    push(pts, Pt{x: i, y: -i});
    if i % 3 == 0 { push(colors, Color.red); } else { push(colors, Color.blue); }
    if has(counts, i % 97) { counts[i % 97] = counts[i % 97] + 1; } else { counts[i % 97] = 1; }
    let s = strings.repeat("n", 8) + to_str(i);
    push(names, s);
    push(tagged, Tagged{name: s, n: i});
    byname[s] = i;
    // garbage between, so collections land throughout
    let junk = strings.repeat("x", 40) + to_str(i);
    i = i + 1;
}

let ok = true;
let j = 0;
while j < 20000 {
    let s = strings.repeat("n", 8) + to_str(j);
    if ints[j] != j * 3 { ok = false; }
    if flts[j] != (j as float) / 2.0 { ok = false; }
    if pts[j].x != j || pts[j].y != -j { ok = false; }
    if names[j] != s || tagged[j].name != s || tagged[j].n != j { ok = false; }
    if !has(byname, s) || byname[s] != j { ok = false; }
    j = j + 1;
}
let total = 0;
for k, v in counts { total = total + v; }
let reds = 0;
for c in colors { if c == Color.red { reds = reds + 1; } }
println("ok: " + to_str(ok));
println("counts: " + to_str(total));
println("reds: " + to_str(reds));
