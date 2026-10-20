// A loop's hoisted GC bracket held the values its roots had when the
// loop began. A body that reassigns a pointer -- `body = body + line` --
// left the bracket holding the first string, and the loop's own sampled
// yield checked in with that stale snapshot: the live string was swept
// once it passed ~35-50 KB (a segfault, or a silently truncated result).
// Every iteration now refreshes the snapshot before checking in.
gc struct Doc {
    lines: [str],
    cells: map[str]str,
    raw: bytes,
}

fn by_list(d: Doc) -> str {
    let body = "";
    for line in d.lines {
        body = body + line + "\n";
    }
    return body;
}

fn by_map(d: Doc) -> str {
    let body = "";
    for k, v in d.cells {
        body = body + k + "=" + v + "\n";
    }
    return body;
}

fn by_bytes(d: Doc) -> str {
    let body = "";
    for b in d.raw {
        body = body + "byte value " + to_str(b) + "\n";
    }
    return body;
}

fn by_while(d: Doc) -> str {
    let body = "";
    let i = 0;
    while i < len(d.lines) {
        body = body + d.lines[i] + "\n";
        i += 1;
    }
    return body;
}

fn check(what: str, got: str, want: int) {
    if len(got) != want {
        println("FAIL " + what + ": " + to_str(len(got)) + " bytes, want " + to_str(want));
        exit(1);
    }
}

let lines: [str] = [];
let cells: map[str]str = {};
let want_list = 0;
let want_map = 0;
for i in 0..4000 {
    let line = "line number " + to_str(i) + " with some padding text";
    push(lines, line);
    want_list += len(line) + 1;
    let key = "k" + to_str(i);
    let val = "value " + to_str(i * 7) + " padded out a little";
    cells[key] = val;
    want_map += len(key) + len(val) + 2;
}
let builder_bytes = "";
for i in 0..3000 {
    builder_bytes = builder_bytes + "x";
}
let d = Doc { lines: lines, cells: cells, raw: to_bytes(builder_bytes) };
let want_bytes = 3000 * len("byte value 120\n");
for round in 0..15 {
    check("for-in list", by_list(d), want_list);
    check("for-in map", by_map(d), want_map);
    check("for-in bytes", by_bytes(d), want_bytes);
    check("while", by_while(d), want_list);
}
println("loop roots stay current");
