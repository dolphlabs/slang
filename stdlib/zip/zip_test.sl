import "builder";
import "strings";

// A copy to damage: to_str would stop at the first NUL.
fn copy(b: bytes) -> bytes {
    return builder.new_bytes().write(b).finish();
}

fn archive(w: Writer) -> bytes {
    let r = w.finish();
    guard let b = r else let e = err_of(r) { panic(e); }
    return b;
}

fn opened(b: bytes) -> Archive {
    let r = open(b);
    guard let a = r else let e = err_of(r) { panic(e); }
    return a;
}

fn refused(b: bytes) -> str {
    let r = open(b);
    guard let _a = r else let e = err_of(r) { return e; }
    panic("opened a bad archive");
}

fn sample() -> bytes {
    let w = new_writer();
    w.add("docs/a.txt", to_bytes(strings.repeat("abc ", 100)), 1715953530);
    w.add_stored("b.bin", b"stored", 1715953531);
    w.add_dir("empty", 1715953530);
    return archive(w);
}

fn test_round_trip_keeps_names_times_and_bytes() {
    let a = opened(sample());
    assert(len(a.entries) == 3);
    let e = a.entries[0];
    assert(e.name == "docs/a.txt" && e.method == 8 && e.size == 400 && e.compressed_size < 400);
    // MS-DOS time has 2-second steps.
    assert(e.modified == 1715953530 && a.entries[1].modified == 1715953530, to_str(e.modified));
    assert(e.mode == 420 && a.entries[2].is_dir && a.entries[2].name == "empty/" && a.entries[2].mode == 493);
    assert(to_str(read(a, e) ?? b"") == strings.repeat("abc ", 100));
    let found = find(a, "b.bin") ?? e;
    assert(found.method == 0 && to_str(read(a, found) ?? b"") == "stored");
}

fn test_damage_is_found() {
    let b = sample();
    // A flipped byte inside the first entry's deflated data.
    let bad = copy(b);
    bad[50] = bad[50] ^ (255 as u8);
    let a = opened(bad);
    let r = read(a, a.entries[0]);
    guard let _x = r else let e = err_of(r) { assert(strings.contains(e, "docs/a.txt"), e); return_more(b); return; }
    panic("read a damaged entry");
}

fn return_more(b: bytes) {
    assert(strings.contains(refused(b[0..len(b) - 5]), "no end of central directory"));
    assert(strings.contains(refused(b"PK"), "too short"));
    // Central directory offset pointing past the end.
    let n = len(b);
    let off = copy(b);
    off[n - 6] = 255 as u8;
    assert(strings.contains(refused(off), "outside the archive"));
}

fn test_overlapping_entries_are_refused() {
    // Two central entries pointing at the same local header.
    let w = new_writer();
    w.add_stored("x", b"payload", 0);
    w.add_stored("y", b"payload", 0);
    let b = copy(archive(w));
    let n = len(b);
    let cd = le32(b, n - 6);
    let second = cd + 46 + 1;
    // y's local header offset := x's (0)
    for i in 0..4 {
        b[second + 42 + i] = 0 as u8;
    }
    assert(strings.contains(refused(b), "overlap"), refused(b));
}

fn test_limits_bound_what_is_inflated() {
    let w = new_writer();
    w.add("zeros", to_bytes(strings.repeat("0", 100000)), 0);
    let b = archive(w);
    let lim = default_limits();
    lim.max_entry_bytes = 1000;
    let r = open_with(b, lim);
    guard let a = r else let e = err_of(r) { panic(e); }
    let rr = read(a, a.entries[0]);
    guard let _x = rr else let e = err_of(rr) { assert(strings.contains(e, "entry limit"), e); return; }
    panic("read past the entry limit");
}

fn test_safe_paths() {
    assert((safe_path("a/./b//c.txt") ?? "") == "a/b/c.txt");
    assert((safe_path("dir/") ?? "") == "dir/");
    for bad in ["../x", "a/../../x", "/etc/passwd", "C:\\x", "c:x", "a\\b", "", ".", "./"] {
        let r = safe_path(bad);
        guard let _p = r else { continue; }
        panic("accepted " + bad);
    }
}

fn test_writer_refuses_bad_names() {
    for bad in ["../evil", "/abs", "a//b", "dup"] {
        let w = new_writer();
        if bad == "dup" {
            w.add("dup", b"1", 0);
        }
        w.add(bad, b"x", 0);
        let r = w.finish();
        guard let _b = r else { continue; }
        panic("wrote " + bad);
    }
}

fn test_dos_times() {
    let d = unix_to_dos(1715953530);
    assert(dos_to_unix(d.date, d.time) == 1715953530);
    let clamp = unix_to_dos(0);
    assert(dos_to_unix(clamp.date, clamp.time) == 315532800, "1980-01-01, the earliest DOS date");
}
