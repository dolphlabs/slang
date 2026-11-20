// zip and tar against archives other tools wrote -- Python's zipfile
// (deflated, stored, a directory, UTF-8 names, a comment; and a forced
// ZIP64 entry), Info-ZIP's zip, Python's tarfile in pax and GNU formats
// (a 134-byte name, a symlink, a UTF-8 name) and macOS bsdtar (ustar) --
// and the other way: what zip and tar write, read back.
import "encoding";
import "fs";
import "strings";
import "tar";
import "zip";

fn slurp(path: str) -> bytes {
    let or = fs.open(path);
    guard let fd = or else let e = err_of(or) { panic(path + ": " + e); }
    let out: bytes = b"";
    while true {
        let rr = fs.read(fd as int, 65536);
        guard let chunk = rr else let e = err_of(rr) { panic(e); }
        if len(chunk) == 0 {
            break;
        }
        out = out + chunk;
    }
    fs.close(fd as int);
    return out;
}

fn show_zip(label: str, data: bytes) {
    let r = zip.open(data);
    guard let a = r else let e = err_of(r) { println(label + ": " + e); return; }
    println(label + ": " + to_str(len(a.entries)) + " entries, comment " + a.comment);
    for e in a.entries {
        let line = "  " + e.name + " size=" + to_str(e.size) + " method=" + to_str(e.method) +
            " mtime=" + to_str(e.modified) + " dir=" + to_str(e.is_dir);
        if !e.is_dir {
            let br = zip.read(a, e);
            guard let body = br else let er = err_of(br) { println(line + " read: " + er); continue; }
            line = line + " head=" + encoding.hex_encode(body[0..min_int(len(body), 6)]);
        }
        println(line);
    }
}

fn min_int(a: int, b: int) -> int {
    if a < b { return a; }
    return b;
}

fn show_tar(label: str, data: bytes) {
    let r = tar.parse(data);
    guard let es = r else let e = err_of(r) { println(label + ": " + e); return; }
    println(label + ": " + to_str(len(es)) + " entries");
    for e in es {
        println("  " + e.name + " kind=" + to_str(e.kind) + " size=" + to_str(e.size) + " mode=" +
                to_str(e.mode) + " mtime=" + to_str(e.modified) + " target=" + e.target + " data=" +
                strings.trim(to_str(e.data)));
    }
}

let dir = "tests/archive_interop/";
show_zip("python.zip", slurp(dir + "python.zip"));
show_zip("zip64.zip", slurp(dir + "zip64.zip"));
show_zip("infozip.zip", slurp(dir + "infozip.zip"));
show_tar("pax.tar", slurp(dir + "pax.tar"));
show_tar("gnu.tar", slurp(dir + "gnu.tar"));
show_tar("bsdtar.tar", slurp(dir + "bsdtar.tar"));

// Round trips.
let w = zip.new_writer();
w.add("a/readme.md", to_bytes(strings.repeat("compress me ", 50)), 1715953530);
w.add_stored("a/raw.bin", b"stored as is", 1715953531);
w.add_dir("a/empty", 1715953530);
let zr = w.finish();
guard let zb = zr else let e = err_of(zr) { panic(e); }
show_zip("written.zip", zb);
let tw = tar.new_writer();
tw.add_dir("app", 493, 1715953530);
tw.add_file("app/" + strings.repeat("n", 140) + ".txt", b"long name", 420, 1715953530);
tw.add_file("app/ünï.txt", b"utf8", 384, 1715953530);
tw.add_symlink("app/current", "releases/42", 1715953530);
let tr = tw.finish();
guard let tb = tr else let e = err_of(tr) { panic(e); }
show_tar("written.tar", tb);
