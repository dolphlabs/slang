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

fn parsed(b: bytes) -> [Entry] {
    let r = parse(b);
    guard let es = r else let e = err_of(r) { panic(e); }
    return es;
}

fn refused(b: bytes) -> str {
    let r = parse(b);
    guard let _e = r else let e = err_of(r) { return e; }
    panic("parsed a bad archive");
}

fn test_round_trip() {
    let w = new_writer();
    w.add_dir("app", 493, 1715953530);
    w.add_file("app/run.sh", b"#!/bin/sh\n", 493, 1715953530);
    let long = "app/" + strings.repeat("d", 150) + "/file.txt";
    w.add_file(long, b"long", 420, 1715953531);
    w.add_symlink("app/cur", "releases/" + strings.repeat("r", 120), 1715953532);
    let es = parsed(archive(w));
    assert(len(es) == 4);
    assert(es[0].name == "app/" && es[0].kind == Kind.Dir && es[0].mode == 493);
    assert(es[1].name == "app/run.sh" && es[1].kind == Kind.File && to_str(es[1].data) == "#!/bin/sh\n");
    assert(es[2].name == long && to_str(es[2].data) == "long" && es[2].modified == 1715953531, es[2].name);
    assert(es[3].kind == Kind.Symlink && es[3].target == "releases/" + strings.repeat("r", 120));
}

fn test_checksums_and_truncation() {
    let w = new_writer();
    w.add_file("a.txt", b"hello", 420, 0);
    let b = archive(w);
    let bad = copy(b);
    bad[10] = 65 as u8;
    assert(strings.contains(refused(bad), "checksum"), refused(bad));
    assert(strings.contains(refused(b[0..300]), "ends inside a header"));
    // Header says 5 bytes but the archive stops after the header.
    assert(strings.contains(refused(b[0..515]), "past the end"), refused(b[0..515]));
    assert(len(parsed(b[0..1024])) == 1, "one end block is enough");
}

fn test_numbers() {
    let h = to_bytes(strings.repeat(" ", 12));
    for i in 0..12 {
        h[i] = 0 as u8;
    }
    // GNU base-256: 0x80 then the value big-endian.
    h[0] = 128 as u8;
    h[10] = 1 as u8;
    h[11] = 2 as u8;
    assert((number(h, 0, 12) ?? -1) == 258);
    assert((number(to_bytes("  0000644  "), 0, 11) ?? -1) == 420);
    let r = number(to_bytes("12x4567"), 0, 7);
    guard let _v = r else { return; }
    panic("read a non-octal number");
}

fn test_safe_paths() {
    assert((safe_path("./a/b") ?? "") == "a/b");
    for bad in ["../x", "/abs", "a/../../b", "x\\y"] {
        let r = safe_path(bad);
        guard let _p = r else { continue; }
        panic("accepted " + bad);
    }
}

fn test_pax_records() {
    let b = to_bytes("29 path=a/very/long/name.txt\n19 linkpath=target\n");
    let r = pax_records(b, 0, len(b));
    guard let m = r else let e = err_of(r) { panic(e); }
    assert(m["path"] == "a/very/long/name.txt" && m["linkpath"] == "target");
    let bad = to_bytes("99 path=x\n");
    let br = pax_records(bad, 0, len(bad));
    guard let _m = br else { return; }
    panic("accepted a bad pax length");
}
