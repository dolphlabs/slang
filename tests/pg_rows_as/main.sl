import "pg";
import "builder";
import "json";
import "strings";
import "timez";

fn rows(names: [str], types: [int], cells: [opt[bytes]], binary: bool) -> pg.Rows {
    assert(len(names) > 0 && len(names) == len(types) && len(cells) % len(names) == 0);
    let data = builder.new_bytes();
    let locs: [int] = [];
    let lens: [int] = [];
    let offset = 0;
    for cell in cells {
        push(locs, offset);
        if let bytes_ = cell { push(lens, len(bytes_)); data.write(bytes_); offset += len(bytes_); }
        else { push(lens, -1); }
    }
    return pg.Rows { columns: names, types: types, binary_results: binary,
        count: len(cells) / len(names), affected: 0, tag: "SELECT", chunks: [data.finish()],
        locs: locs, lens: lens, chunk_gen: 0, stream: 0, done: true };
}
struct Basic { id: int, name: str, nickname: opt[str] }
let input = rows(["name", "ignored", "id"], [25, 25, 20],
    [some(b"Ada"), some(b"discard"), some(b"42"), some(b"Lin"), some(b"discard"), some(b"-7")], false);
let converted: result[[Basic], str] = pg.rows_as(input);
guard let users = converted else let e = err_of(converted) { panic(e); }
assert(len(users) == 2 && users[0].id == 42 && users[1].id == -7 && users[0].name == "Ada");
assert((users[0].nickname ?? "missing") == "missing");
println("named rows and missing optional ok");
let binary = rows(["id", "name", "nickname"], [20, 25, 25],
    [some(to_be(-9223372036854775808)), some(b"binary"), some(b"nick")], true);
let mapped: result[[Basic], str] = pg.rows_as(binary);
guard let bin = mapped else let e = err_of(mapped) { panic(e); }
assert(bin[0].id == -9223372036854775808 && (bin[0].nickname ?? "") == "nick");
println("binary int64 and optional text ok");

struct Details { tags: [str], count: int }
enum Colour { Red, Blue }
gc struct Rich {
    amount: float, exact: u64, active: bool, payload: bytes,
    at: timez.Time, naive: timez.Time, colour: Colour,
    details: opt[Details], missing: opt[int], label: str,
}
let rich_rows = rows(["amount", "exact", "active", "payload", "at", "naive", "colour", "details", "label"],
    [1700, 1700, 16, 17, 1184, 1114, 25, 3802, 25],
    [some(b"3.25"), some(b"18446744073709551615"), some(b"t"), some(b"\\x00ff6869"),
     some(b"2026-10-13 09:30:15.123456+05:30"), some(b"2026-10-13 09:30:15"), some(b"Blue"),
     some(b"{\"tags\":[\"hot\",\"new\"],\"count\":4}"), some(to_bytes("café \"tea\"\n"))], false);
let rich_result: result[[Rich], str] = pg.rows_as(rich_rows);
guard let rich = rich_result else let e = err_of(rich_result) { panic(e); }
assert(rich[0].amount == 3.25 && to_str(rich[0].exact) == "18446744073709551615" && rich[0].active);
assert(rich[0].payload == b"\x00\xffhi" && rich[0].colour == Colour.Blue);
assert(json.encode(rich[0].at) == "\"2026-10-13T04:00:15.123456Z\"");
assert(json.encode(rich[0].naive) == "\"2026-10-13T09:30:15Z\"");
guard let details = rich[0].details else { panic("JSON details absent"); }
assert(details.tags[1] == "new" && details.count == 4 && rich[0].label == "café \"tea\"\n");
println("timestamps bytea enums nested JSON and exact numeric ok");

let null_rows = rows(["details"], [3802], [some(b"null")], false);
struct Nullable { details: opt[Details] }
let null_result: result[[Nullable], str] = pg.rows_as(null_rows);
guard let nulls = null_result else let e = err_of(null_result) { panic(e); }
if let _details = nulls[0].details { panic("JSON null became present"); }
println("JSON null optional ok");

let map_rows = rows(["one", "two"], [23, 1700], [some(b"1"), some(b"2.000")], false);
let maps_result: result[[map[str]int], str] = pg.rows_as(map_rows);
guard let maps = maps_result else let e = err_of(maps_result) { panic(e); }
assert(maps[0]["one"] == 1 && maps[0]["two"] == 2);
let wrapped_result: result[[opt[Basic]], str] = pg.rows_as(input);
guard let wrapped = wrapped_result else let e = err_of(wrapped_result) { panic(e); }
guard let wrapped_row = wrapped[0] else { panic("row object became absent"); }
assert(wrapped_row.id == 42);
println("maps and optional row wrappers ok");

struct Narrow { id: i8 }
let small = rows(["id"], [21], [some(to_be(-128)[6..])], true);
let narrow_result: result[[Narrow], str] = pg.rows_as(small);
guard let narrow = narrow_result else let e = err_of(narrow_result) { panic(e); }
assert(narrow[0].id == -128);
for malformed in [rows(["id"], [20], [some(to_be(128))], true),
                  rows(["id"], [23], [some(b"x")], true),
                  rows(["id"], [25], [some(b"7")], false)] {
    let failed: result[[Narrow], str] = pg.rows_as(malformed);
    guard let _n = failed else let e = err_of(failed) {
        assert(strings.contains(e, "row 0") && strings.contains(e, "field 'id'")); continue;
    }
    panic("invalid narrow cell accepted");
}
let absent_name = rows(["id"], [20], [some(b"1")], false);
let absent_result: result[[Basic], str] = pg.rows_as(absent_name);
if let _absent = absent_result { panic("missing required name accepted"); } else let e = err_of(absent_result) {
    assert(strings.contains(e, "row 0") && strings.contains(e, "name"));
}
let empty = rows(["id"], [20], [], false);
let empty_result: result[[Basic], str] = pg.rows_as(empty);
guard let empty_list = empty_result else let e = err_of(empty_result) { panic(e); }
assert(len(empty_list) == 0);
let broken = rows(["id"], [20], [some(b"1")], false);
broken.locs[0] = 4294967296;
let broken_result: result[[Narrow], str] = pg.rows_as(broken);
if let _broken = broken_result { panic("bad cell location accepted"); } else let e = err_of(broken_result) { assert(strings.contains(e, "location")); }
println("named type range missing storage and empty-result checks ok");

gc struct Node { value: int, next: opt[Node] }
struct Tree { root: Node }
let nested = "null";
let depth = 0;
while depth < 180 { nested = "{\"value\":" + to_str(depth) + ",\"next\":" + nested + "}"; depth += 1; }
let tree_rows = rows(["root"], [114], [some(to_bytes(nested))], false);
let tree_result: result[[Tree], str] = pg.rows_as(tree_rows);
guard let trees = tree_result else let e = err_of(tree_result) { panic(e); }
let node: opt[Node] = some(trees[0].root);
let seen = 0;
while true { guard let current = node else { break; } seen += 1; node = current.next; }
assert(seen == 180);
println("recursive JSON column reserves stack ok");

fn worker(input: pg.Rows, n: int) -> int {
    let total = 0;
    let i = 0;
    while i < n {
        let decoded: result[[Basic], str] = pg.rows_as(input);
        guard let list = decoded else let e = err_of(decoded) { panic(e); }
        let churn = strings.repeat("x", 2048);
        assert(len(churn) == 2048 && list[0].name == "Ada" && list[1].name == "Lin");
        total += list[0].id + list[1].id; i += 1;
    }
    return total;
}
let a = spawn worker(input, 200);
let b = spawn worker(input, 200);
let c = spawn worker(input, 200);
let d = spawn worker(input, 200);
assert((join_wait(a) ?? 0) + (join_wait(b) ?? 0) + (join_wait(c) ?? 0) + (join_wait(d) ?? 0) == 28000);
println("concurrent decoding retains owned fields ok");

struct Empty {}
let empty_shape_result: result[[Empty], str] = pg.rows_as(input);
guard let empty_shapes = empty_shape_result else let e = err_of(empty_shape_result) { panic(e); }
assert(len(empty_shapes) == 2);
struct EmptyDetail { empty: Empty }
struct EmptyJson { detail: EmptyDetail }
let empty_json_rows = rows(["detail"], [3802], [some(b"{\"empty\":{}}")], false);
let empty_json_result: result[[EmptyJson], str] = pg.rows_as(empty_json_rows);
guard let empty_json = empty_json_result else let e = err_of(empty_json_result) { panic(e); }
assert(len(empty_json) == 1);
let invalid_meta = rows(["id"], [20], [some(b"1")], false);
invalid_meta.count = -1;
let invalid_result: result[[Narrow], str] = pg.rows_as(invalid_meta);
if let _bad = invalid_result { panic("negative row count accepted"); }
else let e = err_of(invalid_result) { assert(strings.contains(e, "metadata")); }
println("empty structs and invalid metadata ok");

struct Scalars { active: bool, payload: bytes }
let scalar_rows = rows(["active", "payload"], [16, 17], [some(b"\x01"), some(b"\x00\xff")], true);
let scalar_result: result[[Scalars], str] = pg.rows_as(scalar_rows);
guard let scalars = scalar_result else let e = err_of(scalar_result) { panic(e); }
assert(scalars[0].active && scalars[0].payload == b"\x00\xff");
for malformed in [rows(["active", "payload"], [16, 17], [some(b"\x02"), some(b"")], true),
                  rows(["active", "payload"], [16, 17], [none, some(b"\\x00")], false),
                  rows(["active", "payload"], [16, 17], [some(b"t"), some(b"\\xzz")], false)] {
    let failed: result[[Scalars], str] = pg.rows_as(malformed);
    if let _bad = failed { panic("invalid scalar accepted"); }
    else let e = err_of(failed) { assert(strings.contains(e, "row 0")); }
}
struct Text { value: str }
for special in [rows(["value"], [701], [some(b"NaN")], false),
                rows(["value"], [1184], [some(b"infinity")], false)] {
    let mapped_text: result[[Text], str] = pg.rows_as(special);
    guard let texts = mapped_text else let e = err_of(mapped_text) { panic(e); }
    assert(texts[0].value == "NaN" || texts[0].value == "infinity");
}
let duplicates = rows(["id", "id"], [23, 23], [some(b"1"), some(b"2")], false);
let dup_struct: result[[Narrow], str] = pg.rows_as(duplicates);
guard let first = dup_struct else let e = err_of(dup_struct) { panic(e); }
assert(first[0].id == 1);
let dup_map: result[[map[str]int], str] = pg.rows_as(duplicates);
guard let last = dup_map else let e = err_of(dup_map) { panic(e); }
assert(last[0]["id"] == 2);
println("binary scalars null failures special values and duplicate names ok");
