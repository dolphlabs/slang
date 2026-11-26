// Zip archives (PKWARE APPNOTE 6.3), read and written in memory: stored
// and deflated entries, ZIP64, UTF-8 names.
//
//     import "zip";
//
//     guard let arc = zip.open(data) else |e| { panic(e); }
//     for e in arc.entries {
//         let pr = zip.safe_path(e.name);       // refuses ../, /abs, C:\ ...
//         guard let rel = pr else { continue; }
//         if e.is_dir { continue; }
//         guard let body = zip.read(arc, e) else |er| { panic(er); }   // inflated, size and CRC-32 checked
//         // write body under rel ...
//     }
//
//     let w = zip.new_writer();
//     w.add("report.csv", csv_bytes, now_unix);   // deflated
//     w.add_stored("logo.png", png, now_unix);     // already compressed
//     let out = w.finish();                        // result[bytes, str]
//
// The archive is read from its central directory, as unzip does, and
// every entry is checked against it: the local header's signature, data
// inside the archive, entries that do not overlap (overlapping entries are
// how a 40 KB file becomes petabytes), and the inflated size and CRC-32
// equal to what the directory says. Limits.max_entry_bytes and
// max_total_bytes bound what one entry and all of them may inflate to.
// Encrypted entries and methods other than stored and deflate are listed
// but not read. Names must be UTF-8 (the language-encoding flag, or
// already valid UTF-8, as macOS writes them); CP437 names are refused.
//
// Times are Unix seconds. Zip's own MS-DOS timestamps have no time zone
// and 2-second steps; they are read as UTC, and an entry's extended
// timestamp (extra field 0x5455) wins when it is there.

import "builder";
import "compress";
import "strings";
import "unicode";

pub gc struct Entry {
    name: str,
    // Bytes once inflated, and as stored.
    size: int,
    compressed_size: int,
    // 0 stored, 8 deflate; others cannot be read.
    method: int,
    crc32: int,
    modified: int,
    is_dir: bool,
    encrypted: bool,
    // Unix permission bits when the archive was made on Unix, else 0.
    mode: int,
    comment: str,
    // Where the entry's local header starts.
    offset: int,
}

pub gc struct Archive {
    data: bytes,
    entries: [Entry],
    comment: str,
    lim: Limits,
    // Bytes inflated so far by read, against lim.max_total_bytes.
    inflated: int,
}

pub struct Limits {
    max_entries: int,
    max_entry_bytes: int,
    max_total_bytes: int,
}

pub fn default_limits() -> Limits {
    return Limits { max_entries: 65536, max_entry_bytes: 268435456, max_total_bytes: 1073741824 };
}

let SIG_LOCAL = 67324752;       // 0x04034b50
let SIG_CENTRAL = 33639248;     // 0x02014b50
let SIG_EOCD = 101010256;       // 0x06054b50
let SIG_EOCD64 = 101075792;     // 0x06064b50
let SIG_LOC64 = 117853008;      // 0x07064b50
let U16 = 65535;
let U32 = 4294967295;

fn le16(b: bytes, i: int) -> int {
    return (b[i] as int) | ((b[i + 1] as int) << 8);
}

fn le32(b: bytes, i: int) -> int {
    return le16(b, i) | (le16(b, i + 2) << 16);
}

fn le64(b: bytes, i: int) -> int {
    return le32(b, i) | (le32(b, i + 4) << 32);
}

// ---------------------------------------------------------------- //
// Reading                                                            //
// ---------------------------------------------------------------- //

pub fn open(data: bytes) -> result[Archive, str] {
    return open_with(data, default_limits());
}

pub fn open_with(data: bytes, lim: Limits) -> result[Archive, str] {
    let n = len(data);
    if n < 22 {
        return err("zip: too short to be a zip archive");
    }
    // The end record is the last thing in the file, before a comment of
    // at most 65535 bytes.
    let eocd = -1;
    let i = n - 22;
    let stop = n - 22 - 65535;
    if stop < 0 {
        stop = 0;
    }
    while i >= stop {
        if le32(data, i) == SIG_EOCD && i + 22 + le16(data, i + 20) == n {
            eocd = i;
            break;
        }
        i -= 1;
    }
    if eocd < 0 {
        return err("zip: no end of central directory record (not a zip, or truncated)");
    }
    let count = le16(data, eocd + 10);
    let cd_size = le32(data, eocd + 12);
    let cd_off = le32(data, eocd + 16);
    let comment = strings.from_bytes(data, eocd + 22, n);
    if le16(data, eocd + 4) != 0 || le16(data, eocd + 6) != 0 {
        return err("zip: multi-disk archives are not supported");
    }
    if count == U16 || cd_size == U32 || cd_off == U32 {
        let loc = eocd - 20;
        if loc < 0 || le32(data, loc) != SIG_LOC64 {
            return err("zip: ZIP64 sizes without a ZIP64 locator");
        }
        let rec = le64(data, loc + 8);
        if rec < 0 || rec + 56 > loc || le32(data, rec) != SIG_EOCD64 {
            return err("zip: a bad ZIP64 end of central directory record");
        }
        count = le64(data, rec + 32);
        cd_size = le64(data, rec + 40);
        cd_off = le64(data, rec + 48);
    }
    if count > lim.max_entries {
        return err("zip: " + to_str(count) + " entries, more than the limit of " + to_str(lim.max_entries));
    }
    if cd_off < 0 || cd_size < 0 || cd_off + cd_size > eocd {
        return err("zip: the central directory lies outside the archive");
    }
    let entries: [Entry] = [];
    let pos = cd_off;
    for k in 0..count {
        let er = central_entry(data, pos, cd_off + cd_size, k);
        guard let e = er else let msg = err_of(er) { return err(msg); }
        pos = e.offset;
        push(entries, e.entry);
    }
    let ov = check_layout(data, entries, cd_off);
    guard let _o = ov else let msg = err_of(ov) { return err(msg); }
    return ok(Archive { data: data, entries: entries, comment: comment, lim: lim, inflated: 0 });
}

// One parsed entry and where the next one starts.
struct Parsed { entry: Entry, offset: int }

fn central_entry(b: bytes, pos: int, end: int, k: int) -> result[Parsed, str] {
    let at = "zip: entry " + to_str(k) + ": ";
    if pos + 46 > end || le32(b, pos) != SIG_CENTRAL {
        return err(at + "a bad central directory header");
    }
    let made_by = le16(b, pos + 4) >> 8;
    let flags = le16(b, pos + 8);
    let method = le16(b, pos + 10);
    let dtime = le16(b, pos + 12);
    let ddate = le16(b, pos + 14);
    let crc = le32(b, pos + 16);
    let csize = le32(b, pos + 20);
    let usize = le32(b, pos + 24);
    let name_len = le16(b, pos + 28);
    let extra_len = le16(b, pos + 30);
    let comment_len = le16(b, pos + 32);
    let disk = le16(b, pos + 34);
    let ext_attr = le32(b, pos + 38);
    let offset = le32(b, pos + 42);
    let next = pos + 46 + name_len + extra_len + comment_len;
    if next > end {
        return err(at + "its header runs past the central directory");
    }
    let raw_name = b[pos + 46..pos + 46 + name_len];
    if !unicode.valid_bytes(raw_name) {
        return err(at + "the name is not UTF-8 (CP437 names are not supported)");
    }
    if len(raw_name) == 0 {
        return err(at + "an empty name");
    }
    for c in raw_name {
        if c == 0 {
            return err(at + "a NUL in the name");
        }
    }
    let name = to_str(raw_name);
    let modified = dos_to_unix(ddate, dtime);
    // Extra fields: ZIP64 sizes (0x0001), extended timestamp (0x5455).
    let x = pos + 46 + name_len;
    let xend = x + extra_len;
    while x + 4 <= xend {
        let id = le16(b, x);
        let sz = le16(b, x + 2);
        let d = x + 4;
        if d + sz > xend {
            return err(at + "an extra field runs past its header");
        }
        if id == 1 {
            let q = d;
            if usize == U32 {
                if q + 8 > d + sz { return err(at + "a short ZIP64 field"); }
                usize = le64(b, q);
                q += 8;
            }
            if csize == U32 {
                if q + 8 > d + sz { return err(at + "a short ZIP64 field"); }
                csize = le64(b, q);
                q += 8;
            }
            if offset == U32 {
                if q + 8 > d + sz { return err(at + "a short ZIP64 field"); }
                offset = le64(b, q);
                q += 8;
            }
        } else if id == 21589 && sz >= 5 && (b[d] & 1) == 1 {
            let t = le32(b, d + 1);
            if t >= 2147483648 {
                t = t - 4294967296;
            }
            modified = t;
        }
        x = d + sz;
    }
    if disk != 0 && disk != U16 {
        return err(at + "on another disk");
    }
    if usize < 0 || csize < 0 || offset < 0 {
        return err(at + "a size or offset past 2^63");
    }
    let mode = 0;
    if made_by == 3 {
        mode = (ext_attr >> 16) & 4095;
    }
    let comment = to_str(b[next - comment_len..next]);
    let e = Entry { name: name, size: usize, compressed_size: csize, method: method, crc32: crc,
                    modified: modified, is_dir: strings.has_suffix(name, "/"), encrypted: (flags & 1) == 1,
                    mode: mode, comment: comment, offset: offset };
    return ok(Parsed { entry: e, offset: next });
}

// Each entry's local header and data inside the archive, before the
// central directory, and no two entries sharing bytes.
fn check_layout(b: bytes, entries: [Entry], cd_off: int) -> result[bool, str] {
    let starts: [int] = [];
    let ends: [int] = [];
    for e in entries {
        let dr = data_start(b, e, cd_off);
        guard let d = dr else let msg = err_of(dr) { return err(msg); }
        if d + e.compressed_size > cd_off {
            return err("zip: " + e.name + ": its data runs past the central directory");
        }
        push(starts, e.offset);
        push(ends, d + e.compressed_size);
    }
    // Sorted by start, each must end before the next begins.
    let order = sorted_indexes(starts);
    for k in 1..len(order) {
        if starts[order[k]] < ends[order[k - 1]] {
            return err("zip: entries " + entries[order[k - 1]].name + " and " + entries[order[k]].name +
                       " overlap (a zip bomb, or a damaged archive)");
        }
    }
    return ok(true);
}

fn sorted_indexes(xs: [int]) -> [int] {
    let idx: [int] = [];
    for i in 0..len(xs) {
        push(idx, i);
    }
    // Bottom-up merge sort: n log n, no recursion.
    let n = len(idx);
    let width = 1;
    let tmp: [int] = [];
    for i in 0..n {
        push(tmp, 0);
    }
    while width < n {
        let lo = 0;
        while lo < n {
            let mid = lo + width;
            if mid > n { mid = n; }
            let hi = lo + 2 * width;
            if hi > n { hi = n; }
            let i = lo;
            let j = mid;
            let k = lo;
            while k < hi {
                if i < mid && (j >= hi || xs[idx[i]] <= xs[idx[j]]) {
                    tmp[k] = idx[i];
                    i += 1;
                } else {
                    tmp[k] = idx[j];
                    j += 1;
                }
                k += 1;
            }
            lo = hi;
        }
        for k in 0..n {
            idx[k] = tmp[k];
        }
        width = width * 2;
    }
    return idx;
}

fn data_start(b: bytes, e: Entry, limit: int) -> result[int, str] {
    let p = e.offset;
    if p + 30 > limit || le32(b, p) != SIG_LOCAL {
        return err("zip: " + e.name + ": no local header where the directory says");
    }
    return ok(p + 30 + le16(b, p + 26) + le16(b, p + 28));
}

// The entry's contents, inflated and checked against its size and CRC-32.
pub fn read(a: Archive, e: Entry) -> result[bytes, str] {
    if e.encrypted {
        return err("zip: " + e.name + ": encrypted entries are not supported");
    }
    if e.size > a.lim.max_entry_bytes {
        return err("zip: " + e.name + ": " + to_str(e.size) + " bytes, more than the entry limit of " +
                   to_str(a.lim.max_entry_bytes));
    }
    if a.inflated + e.size > a.lim.max_total_bytes {
        return err("zip: " + e.name + ": reading it would pass the archive limit of " +
                   to_str(a.lim.max_total_bytes) + " bytes");
    }
    let dr = data_start(a.data, e, len(a.data));
    guard let d = dr else let msg = err_of(dr) { return err(msg); }
    let raw = a.data[d..d + e.compressed_size];
    let out = b"";
    if e.method == 0 {
        if e.compressed_size != e.size {
            return err("zip: " + e.name + ": a stored entry whose sizes differ");
        }
        out = raw;
    } else if e.method == 8 {
        let ir = compress.inflate_raw(raw, e.size);
        guard let v = ir else let msg = err_of(ir) { return err("zip: " + e.name + ": " + msg); }
        out = v;
    } else {
        return err("zip: " + e.name + ": compression method " + to_str(e.method) +
                   " is not supported (stored and deflate are)");
    }
    if len(out) != e.size {
        return err("zip: " + e.name + ": inflated to " + to_str(len(out)) + " bytes, the directory says " +
                   to_str(e.size));
    }
    if compress.crc32(out) != e.crc32 {
        return err("zip: " + e.name + ": CRC-32 mismatch (the archive is damaged)");
    }
    a.inflated += e.size;
    return ok(out);
}

// The entry named `name` exactly, if there is one.
pub fn find(a: Archive, name: str) -> opt[Entry] {
    for e in a.entries {
        if e.name == name {
            return some(e);
        }
    }
    return none;
}

// A name made safe to join under an extraction directory: relative, with
// no "..", no drive letter or backslash, no NUL. A trailing "/" is kept.
// err names what is wrong; extracting such a name is how an archive
// writes outside the directory ("zip slip").
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
// Times                                                              //
// ---------------------------------------------------------------- //

// Days from 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y0: int, m: int, d: int) -> int {
    let y = y0;
    if m <= 2 {
        y -= 1;
    }
    let era = y / 400;
    if y < 0 && y % 400 != 0 {
        era -= 1;
    }
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

fn dos_to_unix(date: int, time: int) -> int {
    let y = 1980 + (date >> 9);
    let mo = (date >> 5) & 15;
    let d = date & 31;
    if mo < 1 || mo > 12 || d < 1 {
        return 0;
    }
    let h = time >> 11;
    let mi = (time >> 5) & 63;
    let s = (time & 31) * 2;
    return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s;
}

struct Dos { date: int, time: int }

fn unix_to_dos(t: int) -> Dos {
    // MS-DOS dates run from 1980 to 2107.
    let lo = days_from_civil(1980, 1, 1) * 86400;
    let hi = days_from_civil(2107, 12, 31) * 86400 + 86399;
    let u = t;
    if u < lo { u = lo; }
    if u > hi { u = hi; }
    let days = u / 86400;
    let secs = u % 86400;
    // civil_from_days
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + 3;
    if m > 12 {
        m -= 12;
    }
    if m <= 2 {
        y += 1;
    }
    return Dos { date: ((y - 1980) << 9) | (m << 5) | d,
                 time: ((secs / 3600) << 11) | (((secs / 60) % 60) << 5) | ((secs % 60) / 2) };
}

// ---------------------------------------------------------------- //
// Writing                                                            //
// ---------------------------------------------------------------- //

pub gc struct Writer {
    out: builder.Bytes,
    size: int,
    central: builder.Bytes,
    count: int,
    names: map[str]bool,
    // The first error from add; finish reports it.
    problem: str,
}

pub fn new_writer() -> Writer {
    let names: map[str]bool = {};
    return Writer { out: builder.new_bytes(), size: 0, central: builder.new_bytes(), count: 0, names: names,
                    problem: "" };
}

fn put16(b: builder.Bytes, v: int) {
    b.write_byte(v & 255);
    b.write_byte((v >> 8) & 255);
}

fn put32(b: builder.Bytes, v: int) {
    put16(b, v & 65535);
    put16(b, (v >> 16) & 65535);
}

impl Writer {
    // Adds a file, deflated (stored instead when deflating does not make it
    // smaller). `modified` is Unix seconds.
    pub fn add(self: Writer, name: str, data: bytes, modified: int) -> Writer {
        return self.add_entry(name, data, modified, true, 420);
    }

    // Adds a file as is: for data that is already compressed.
    pub fn add_stored(self: Writer, name: str, data: bytes, modified: int) -> Writer {
        return self.add_entry(name, data, modified, false, 420);
    }

    // Adds a directory; "/" is appended to the name when missing.
    pub fn add_dir(self: Writer, name: str, modified: int) -> Writer {
        let n = name;
        if !strings.has_suffix(n, "/") {
            n = n + "/";
        }
        return self.add_entry(n, b"", modified, false, 493);
    }

    fn add_entry(self: Writer, name: str, data: bytes, modified: int, deflate: bool, perm: int) -> Writer {
        if len(self.problem) > 0 {
            return self;
        }
        let pr = safe_path(name);
        guard let clean = pr else let e = err_of(pr) {
            self.problem = "zip: " + e;
            return self;
        }
        if clean != name {
            self.problem = "zip: " + name + ": write it as " + clean;
            return self;
        }
        if !unicode.valid(name) || len(to_bytes(name)) > 65535 {
            self.problem = "zip: " + name + ": a name must be UTF-8 and under 64 KiB";
            return self;
        }
        if has(self.names, name) {
            self.problem = "zip: " + name + " is added twice";
            return self;
        }
        // In-memory archives stay below ZIP64's thresholds.
        if len(data) >= U32 || self.size >= U32 - 65536 || self.count >= 65535 {
            self.problem = "zip: the archive would need ZIP64 (4 GiB or 65535 entries); not written";
            return self;
        }
        self.names[name] = true;
        let crc = compress.crc32(data);
        let body = data;
        let method = 0;
        if deflate && len(data) > 0 {
            let dr = compress.deflate_raw(data);
            guard let packed = dr else let e = err_of(dr) {
                self.problem = "zip: " + name + ": " + e;
                return self;
            }
            if len(packed) < len(data) {
                body = packed;
                method = 8;
            }
        }
        let dos = unix_to_dos(modified);
        let nb = to_bytes(name);
        let offset = self.size;
        // Local header. Flag 0x0800: the name is UTF-8.
        put32(self.out, SIG_LOCAL);
        put16(self.out, 20);
        put16(self.out, 2048);
        put16(self.out, method);
        put16(self.out, dos.time);
        put16(self.out, dos.date);
        put32(self.out, crc);
        put32(self.out, len(body));
        put32(self.out, len(data));
        put16(self.out, len(nb));
        put16(self.out, 0);
        self.out.write(nb);
        self.out.write(body);
        self.size += 30 + len(nb) + len(body);
        // Central directory header, made by Unix (3) so the mode survives.
        put32(self.central, SIG_CENTRAL);
        put16(self.central, 788);
        put16(self.central, 20);
        put16(self.central, 2048);
        put16(self.central, method);
        put16(self.central, dos.time);
        put16(self.central, dos.date);
        put32(self.central, crc);
        put32(self.central, len(body));
        put32(self.central, len(data));
        put16(self.central, len(nb));
        put16(self.central, 0);
        put16(self.central, 0);
        put16(self.central, 0);
        put16(self.central, 0);
        let kind = 32768;
        if strings.has_suffix(name, "/") {
            kind = 16384;
        }
        let ext = ((kind | perm) << 16);
        if kind == 16384 {
            ext = ext | 16;
        }
        put32(self.central, ext);
        put32(self.central, offset);
        self.central.write(nb);
        self.count += 1;
        return self;
    }

    // The whole archive, or the first problem an add ran into.
    pub fn finish(self: Writer) -> result[bytes, str] {
        if len(self.problem) > 0 {
            return err(self.problem);
        }
        let cd = self.central.finish();
        let all = builder.new_bytes();
        all.write(self.out.finish());
        all.write(cd);
        put32(all, SIG_EOCD);
        put16(all, 0);
        put16(all, 0);
        put16(all, self.count);
        put16(all, self.count);
        put32(all, len(cd));
        put32(all, self.size);
        put16(all, 0);
        return ok(all.finish());
    }
}
