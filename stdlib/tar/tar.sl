// Tar archives (POSIX ustar and pax, and GNU long names), read and
// written in memory. A .tar.gz is compress.gunzip first.
//
//     import "tar";
//
//     guard let entries = tar.parse(data) else |e| { panic(e); }
//     for e in entries {
//         let pr = tar.safe_path(e.name);       // refuses ../, /abs ...
//         guard let rel = pr else { continue; }
//         if e.kind == tar.Kind.File {
//             // write e.data under rel, with e.mode
//         }
//     }
//
//     let w = tar.new_writer();
//     w.add_file("bin/run.sh", script, 493, now_unix);   // 0755
//     w.add_dir("logs", 493, now_unix);
//     w.add_symlink("current", "releases/42", now_unix);
//     let out = w.finish();                               // result[bytes, str]
//
// Every header's checksum is checked, sizes may be octal or GNU base-256,
// and a pax header's path, linkpath, size, mtime, uid and gid override
// the ustar fields (so names past 100 bytes and files past 8 GiB read
// right). A header that does not check out, data past the end of the
// archive, or more than Limits allows is an error, never a guess.
// Writing uses ustar, and a pax header for a name ustar cannot hold.

import "builder";
import "strings";
import "unicode";

pub enum Kind { File, Dir, Symlink, Hardlink, Other }

pub gc struct Entry {
    name: str,
    kind: Kind,
    // The ustar type flag, for Other ('3' char device, '4' block device,
    // '6' FIFO ...).
    flag: int,
    size: int,
    mode: int,
    modified: int,
    uid: int,
    gid: int,
    uname: str,
    gname: str,
    // A symlink's or hard link's target.
    target: str,
    data: bytes,
}

pub struct Limits {
    max_entries: int,
    max_total_bytes: int,
}

pub fn default_limits() -> Limits {
    return Limits { max_entries: 65536, max_total_bytes: 1073741824 };
}

let BLOCK = 512;

pub fn parse(data: bytes) -> result[[Entry], str] {
    return parse_with(data, default_limits());
}

gc struct Pax { values: map[str]str }

pub fn parse_with(data: bytes, lim: Limits) -> result[[Entry], str] {
    let out: [Entry] = [];
    let n = len(data);
    let pos = 0;
    let total = 0;
    let global: map[str]str = {};
    let local: map[str]str = {};
    let long_name = "";
    let long_link = "";
    while true {
        if pos + BLOCK > n {
            if pos == n {
                break;
            }
            return err("tar: the archive ends inside a header at byte " + to_str(pos));
        }
        if all_zero(data, pos, pos + BLOCK) {
            // The end: two zero blocks (one, from some writers).
            break;
        }
        let at = "tar: header at byte " + to_str(pos) + ": ";
        let cr = check_sum(data, pos);
        guard let _c = cr else let e = err_of(cr) { return err(at + e); }
        let flag = data[pos + 156] as int;
        let sr = number(data, pos + 124, 12);
        guard let size0 = sr else let e = err_of(sr) { return err(at + "size: " + e); }
        let size = size0;
        if let ps = map_get(local, "size") {
            let r = parse_dec(ps);
            guard let v = r else { return err(at + "pax size " + ps + " is not a number"); }
            size = v;
        }
        let body = pos + BLOCK;
        if size < 0 || body + size > n {
            return err(at + "its " + to_str(size) + " bytes run past the end of the archive");
        }
        let next = body + (size + BLOCK - 1) / BLOCK * BLOCK;
        if next > n {
            next = n;
        }
        if flag == 120 || flag == 103 {
            // 'x' pax for the next entry, 'g' global
            let pr = pax_records(data, body, body + size);
            guard let recs = pr else let e = err_of(pr) { return err(at + e); }
            for k, v in recs {
                if flag == 120 {
                    local[k] = v;
                } else {
                    global[k] = v;
                }
            }
            pos = next;
            continue;
        }
        if flag == 76 || flag == 75 {
            // GNU 'L' long name, 'K' long link name: NUL-terminated data.
            if size > 65536 {
                return err(at + "a GNU long name over 64 KiB");
            }
            let s = c_string(data, body, body + size);
            if flag == 76 {
                long_name = s;
            } else {
                long_link = s;
            }
            pos = next;
            continue;
        }
        if len(out) >= lim.max_entries {
            return err("tar: more than " + to_str(lim.max_entries) + " entries");
        }
        total += size;
        if total > lim.max_total_bytes {
            return err("tar: more than " + to_str(lim.max_total_bytes) + " bytes of entries");
        }
        let name = c_string(data, pos, pos + 100);
        // POSIX ustar ("ustar\0") has a name prefix field; GNU ("ustar  ")
        // uses those bytes for other things.
        let ustar = data[pos + 257] == 117 && data[pos + 258] == 115 && data[pos + 259] == 116 &&
                    data[pos + 260] == 97 && data[pos + 261] == 114;
        if ustar && data[pos + 262] == 0 {
            let prefix = c_string(data, pos + 345, pos + 500);
            if len(prefix) > 0 {
                name = prefix + "/" + name;
            }
        }
        let target = c_string(data, pos + 157, pos + 257);
        let mr = number(data, pos + 100, 8);
        guard let mode = mr else let e = err_of(mr) { return err(at + "mode: " + e); }
        let ur = number(data, pos + 108, 8);
        guard let uid0 = ur else let e = err_of(ur) { return err(at + "uid: " + e); }
        let gr = number(data, pos + 116, 8);
        guard let gid0 = gr else let e = err_of(gr) { return err(at + "gid: " + e); }
        let tr = number(data, pos + 136, 12);
        guard let mtime0 = tr else let e = err_of(tr) { return err(at + "mtime: " + e); }
        let uid = uid0;
        let gid = gid0;
        let mtime = mtime0;
        if len(long_name) > 0 {
            name = long_name;
        }
        if len(long_link) > 0 {
            target = long_link;
        }
        for src in [global, local] {
            if let v = map_get(src, "path") { name = v; }
            if let v = map_get(src, "linkpath") { target = v; }
            if let v = map_get(src, "uid") { uid = parse_dec(v) ?? uid; }
            if let v = map_get(src, "gid") { gid = parse_dec(v) ?? gid; }
            if let v = map_get(src, "mtime") {
                let dot = strings.find(v, ".");
                let whole = v;
                if dot >= 0 { whole = strings.slice(v, 0, dot); }
                mtime = parse_dec(whole) ?? mtime;
            }
        }
        if len(name) == 0 {
            return err(at + "an entry without a name");
        }
        let kind = Kind.Other;
        if flag == 48 || flag == 0 || flag == 55 {
            kind = Kind.File;
        } else if flag == 53 {
            kind = Kind.Dir;
        } else if flag == 50 {
            kind = Kind.Symlink;
        } else if flag == 49 {
            kind = Kind.Hardlink;
        }
        // A pre-POSIX archive marks a directory by its trailing slash.
        if kind == Kind.File && strings.has_suffix(name, "/") {
            kind = Kind.Dir;
        }
        let body_bytes = b"";
        if kind == Kind.File || kind == Kind.Other {
            body_bytes = data[body..body + size];
        }
        push(out, Entry { name: name, kind: kind, flag: flag, size: len(body_bytes), mode: mode & 4095,
                          modified: mtime, uid: uid, gid: gid, uname: c_string(data, pos + 265, pos + 297),
                          gname: c_string(data, pos + 297, pos + 329), target: target, data: body_bytes });
        let cleared: map[str]str = {};
        local = cleared;
        long_name = "";
        long_link = "";
        pos = next;
    }
    return ok(out);
}

fn map_get(m: map[str]str, k: str) -> opt[str] {
    if has(m, k) {
        return some(m[k]);
    }
    return none;
}

fn all_zero(b: bytes, from: int, to: int) -> bool {
    for i in from..to {
        if b[i] != 0 {
            return false;
        }
    }
    return true;
}

// The bytes up to the first NUL, as text (lossy only on invalid UTF-8,
// which is refused).
fn c_string(b: bytes, from: int, to: int) -> str {
    let end = from;
    while end < to && b[end] != 0 {
        end += 1;
    }
    return strings.from_bytes(b, from, end);
}

// The header's checksum: the unsigned sum of its bytes with the checksum
// field read as spaces (some old writers summed signed bytes; that is
// accepted too).
fn check_sum(b: bytes, pos: int) -> result[bool, str] {
    let r = number(b, pos + 148, 8);
    guard let want = r else let e = err_of(r) { return err("checksum: " + e); }
    let unsigned_sum = 0;
    let signed_sum = 0;
    for i in 0..BLOCK {
        let c = b[pos + i] as int;
        if i >= 148 && i < 156 {
            c = 32;
        }
        unsigned_sum += c;
        if c >= 128 {
            signed_sum += c - 256;
        } else {
            signed_sum += c;
        }
    }
    if want != unsigned_sum && want != signed_sum {
        return err("checksum mismatch (not a tar archive, or damaged)");
    }
    return ok(true);
}

// An octal field (NUL- or space-terminated, possibly space-led), or GNU's
// base-256 form (high bit set).
fn number(b: bytes, from: int, width: int) -> result[int, str] {
    if (b[from] & 128) != 0 {
        if (b[from] & 64) != 0 {
            return err("a negative base-256 number");
        }
        let v = (b[from] & 63) as int;
        for i in from + 1..from + width {
            if v > 36028797018963967 {
                return err("a number past 2^63");
            }
            v = (v << 8) | (b[i] as int);
        }
        return ok(v);
    }
    let i = from;
    let end = from + width;
    while i < end && b[i] == 32 {
        i += 1;
    }
    let v = 0;
    let digits = 0;
    while i < end && b[i] >= 48 && b[i] <= 55 {
        if v > 1152921504606846975 {
            return err("a number past 2^63");
        }
        v = v * 8 + (b[i] as int) - 48;
        i += 1;
        digits += 1;
    }
    while i < end {
        if b[i] != 0 && b[i] != 32 {
            return err("not an octal number");
        }
        i += 1;
    }
    return ok(v);
}

fn parse_dec(s: str) -> opt[int] {
    if len(s) == 0 || len(s) > 18 {
        return none;
    }
    let v = 0;
    for c in to_bytes(s) {
        if c < 48 || c > 57 {
            return none;
        }
        v = v * 10 + (c as int) - 48;
    }
    return some(v);
}

// pax records: "<len> <key>=<value>\n", len counting the whole record.
fn pax_records(b: bytes, from: int, to: int) -> result[map[str]str, str] {
    let out: map[str]str = {};
    let pos = from;
    while pos < to {
        let sp = pos;
        while sp < to && b[sp] != 32 {
            sp += 1;
        }
        let lr = parse_dec(strings.from_bytes(b, pos, sp));
        guard let reclen = lr else { return err("a bad pax record length"); }
        let end = pos + reclen;
        if sp >= to || end > to || reclen < 5 || b[end - 1] != 10 {
            return err("a bad pax record");
        }
        let rec = strings.from_bytes(b, sp + 1, end - 1);
        let eq = strings.find(rec, "=");
        if eq <= 0 {
            return err("a pax record without key=value");
        }
        let val = strings.slice(rec, eq + 1, len(rec));
        if !unicode.valid(val) {
            return err("a pax value that is not UTF-8");
        }
        out[strings.slice(rec, 0, eq)] = val;
        pos = end;
    }
    return ok(out);
}

// A name made safe to join under an extraction directory: relative, with
// no "..", no drive letter or backslash, no NUL. A trailing "/" is kept.
// Check a symlink's target the same way before creating it.
pub fn safe_path(name: str) -> result[str, str] {
    if len(name) == 0 {
        return err("an empty name");
    }
    for c in to_bytes(name) {
        if c == 0 || c == 92 {
            return err(name + ": a NUL or backslash in the name");
        }
    }
    if strings.has_prefix(name, "/") {
        return err(name + ": an absolute path");
    }
    let b = to_bytes(name);
    if len(b) >= 2 && b[1] == 58 {
        return err(name + ": a drive letter");
    }
    let parts: [str] = [];
    for seg in strings.split(name, "/") {
        if seg == ".." {
            return err(name + ": a .. segment");
        }
        if seg == "." || len(seg) == 0 {
            continue;
        }
        push(parts, seg);
    }
    if len(parts) == 0 {
        return err(name + ": names nothing");
    }
    let out = strings.join(parts, "/");
    if strings.has_suffix(name, "/") {
        out = out + "/";
    }
    return ok(out);
}

// ---------------------------------------------------------------- //
// Writing                                                            //
// ---------------------------------------------------------------- //

pub gc struct Writer {
    out: builder.Bytes,
    count: int,
    problem: str,
}

pub fn new_writer() -> Writer {
    return Writer { out: builder.new_bytes(), count: 0, problem: "" };
}

fn octal(v: int, width: int) -> bytes {
    // width - 1 digits and a NUL
    let b = to_bytes(strings.repeat("0", width - 1) + " ");
    b[width - 1] = 0 as u8;
    let x = v;
    let i = width - 2;
    while i >= 0 && x > 0 {
        b[i] = (48 + (x % 8)) as u8;
        x = x / 8;
        i -= 1;
    }
    return b;
}

fn fits_octal(v: int, width: int) -> bool {
    let max = 1;
    for _i in 0..width - 1 {
        max = max * 8;
    }
    return v >= 0 && v < max;
}

fn field(h: bytes, at: int, val: bytes) {
    for i in 0..len(val) {
        h[at + i] = val[i];
    }
}

impl Writer {
    pub fn add_file(self: Writer, name: str, data: bytes, mode: int, modified: int) -> Writer {
        return self.add_entry(name, 48, data, "", mode, modified);
    }

    pub fn add_dir(self: Writer, name: str, mode: int, modified: int) -> Writer {
        let n = name;
        if !strings.has_suffix(n, "/") {
            n = n + "/";
        }
        return self.add_entry(n, 53, b"", "", mode, modified);
    }

    pub fn add_symlink(self: Writer, name: str, target: str, modified: int) -> Writer {
        if len(target) == 0 {
            self.problem = "tar: " + name + ": a symlink needs a target";
            return self;
        }
        return self.add_entry(name, 50, b"", target, 511, modified);
    }

    fn add_entry(self: Writer, name: str, flag: int, data: bytes, target: str, mode: int,
                 modified: int) -> Writer {
        if len(self.problem) > 0 {
            return self;
        }
        let pr = safe_path(name);
        guard let clean = pr else let e = err_of(pr) {
            self.problem = "tar: " + e;
            return self;
        }
        if clean != name {
            self.problem = "tar: " + name + ": write it as " + clean;
            return self;
        }
        if !unicode.valid(name) || !unicode.valid(target) {
            self.problem = "tar: " + name + ": names must be UTF-8";
            return self;
        }
        if mode < 0 || mode > 4095 || modified < 0 || !fits_octal(modified, 12) {
            self.problem = "tar: " + name + ": mode must be 0 to 07777 and the time from 1970 on";
            return self;
        }
        let nb = to_bytes(name);
        let lb = to_bytes(target);
        let pax = builder.new_bytes();
        let ustar_name = name;
        if len(nb) > 100 || has_nonascii(nb) {
            pax_record(pax, "path", name);
            ustar_name = strings.from_bytes(nb, 0, cut_ascii(nb, 100));
        }
        let ustar_link = target;
        if len(lb) > 100 || has_nonascii(lb) {
            pax_record(pax, "linkpath", target);
            ustar_link = strings.from_bytes(lb, 0, cut_ascii(lb, 100));
        }
        let size_field = len(data);
        if !fits_octal(len(data), 12) {
            pax_record(pax, "size", to_str(len(data)));
            size_field = 0;
        }
        if !pax.is_empty() {
            let pb = pax.finish();
            self.header("PaxHeaders/" + strings.from_bytes(to_bytes(ustar_name), 0, cut_ascii(to_bytes(ustar_name), 88)),
                        120, len(pb), "", 420, modified);
            self.body(pb);
        }
        self.header(ustar_name, flag, size_field, ustar_link, mode, modified);
        self.body(data);
        self.count += 1;
        return self;
    }

    fn header(self: Writer, name: str, flag: int, size: int, target: str, mode: int, modified: int) {
        let h = to_bytes(strings.repeat(" ", BLOCK));
        for i in 0..BLOCK {
            h[i] = 0 as u8;
        }
        field(h, 0, to_bytes(name));
        field(h, 100, octal(mode, 8));
        field(h, 108, octal(0, 8));
        field(h, 116, octal(0, 8));
        field(h, 124, octal(size, 12));
        field(h, 136, octal(modified, 12));
        field(h, 148, to_bytes("        "));
        h[156] = flag as u8;
        field(h, 157, to_bytes(target));
        field(h, 257, to_bytes("ustar"));
        field(h, 263, to_bytes("00"));
        let sum = 0;
        for c in h {
            sum += c as int;
        }
        let cs = octal(sum, 7);
        field(h, 148, cs);
        h[155] = 32 as u8;
        self.out.write(h);
    }

    fn body(self: Writer, data: bytes) {
        self.out.write(data);
        let pad = (BLOCK - len(data) % BLOCK) % BLOCK;
        if pad > 0 {
            let z = to_bytes(strings.repeat(" ", pad));
            for i in 0..pad {
                z[i] = 0 as u8;
            }
            self.out.write(z);
        }
    }

    // The archive, closed with two zero blocks, or the first problem an
    // add ran into.
    pub fn finish(self: Writer) -> result[bytes, str] {
        if len(self.problem) > 0 {
            return err(self.problem);
        }
        let z = to_bytes(strings.repeat(" ", 2 * BLOCK));
        for i in 0..2 * BLOCK {
            z[i] = 0 as u8;
        }
        self.out.write(z);
        return ok(self.out.finish());
    }
}

fn has_nonascii(b: bytes) -> bool {
    for c in b {
        if c >= 128 {
            return true;
        }
    }
    return false;
}

// How many leading bytes, at most max, are ASCII.
fn cut_ascii(b: bytes, max: int) -> int {
    let i = 0;
    while i < len(b) && i < max && b[i] < 128 {
        i += 1;
    }
    return i;
}

fn pax_record(out: builder.Bytes, key: str, val: str) {
    // The length counts its own digits: try the size with n digits until
    // it agrees.
    let base = len(to_bytes(key)) + len(to_bytes(val)) + 3;
    let n = base + len(to_str(base));
    if len(to_str(n)) != len(to_str(base)) {
        n = base + len(to_str(n));
    }
    out.write(to_bytes(to_str(n) + " " + key + "=" + val + "\n"));
}
