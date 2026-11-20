# zip

> Package zip.

Archives in memory: read every entry of a zip (stored or deflated, ZIP64,
UTF-8 names) or a tar (ustar, pax, GNU long names; a `.tar.gz` is
`compress.gunzip` first), and write either.

```slang
import "tar";
import "zip";

let r = zip.open(data);
guard let arc = r else let e = err_of(r) { panic(e); }
for e in arc.entries {
    let pr = zip.safe_path(e.name);          // refuses ../, /abs, C:\ (zip slip)
    guard let rel = pr else { continue; }
    if !e.is_dir {
        let body = zip.read(arc, e);         // inflated, size and CRC-32 checked
    }
}

let w = zip.new_writer();
w.add("report.csv", csv_bytes, now_unix);    // deflated, or stored if that is smaller
w.add_stored("logo.png", png, now_unix);
let out = w.finish();                        // result[bytes, str]

let tr = tar.parse(tar_bytes);               // result[[tar.Entry], str]
let tw = tar.new_writer();
tw.add_file("bin/run.sh", script, 493, now_unix);    // mode 0755
tw.add_symlink("current", "releases/42", now_unix);
let tb = tw.finish();
```

**Reading is checked against the archive itself.** A zip is read from its
central directory, as unzip does. Each entry's local header must be where
the directory says, its data inside the archive, and no two entries may
share bytes: overlapping entries are how a 40 KB zip claims petabytes.
An entry inflates to at most the size the directory states, and must
match it and its CRC-32. `zip.Limits` bounds one entry (256 MiB), all of
them together (1 GiB) and their count. Every tar header's checksum is
checked, and a size may be octal or GNU base-256. A pax header's `path`,
`linkpath`, `size`, `mtime`, `uid` and `gid` override the ustar fields.
Data past the end of the archive is an error, never a short entry.
Encrypted zip entries and methods other than stored and deflate are
listed but not read. Zip names must be UTF-8, so CP437 names are refused.

**Names are never trusted.** Neither package touches the file system.
`safe_path` gives back a relative, cleaned name, or an error for an
absolute path, a `..` segment, a drive letter, a backslash or a NUL.
Check a tar symlink's target the same way before creating it. Writers
refuse such names, and the same name twice.

**Times** are Unix seconds. A zip's MS-DOS timestamp has no zone and
2-second steps; it is read as UTC, and the extended timestamp extra field
wins when present. `tests/archive_interop` reads archives made by
Python's `zipfile` and `tarfile`, Info-ZIP and bsdtar. What these writers
write was checked with `unzip -t`, Python and bsdtar.

## API

### `gc struct Entry`

### `gc struct Archive`

### `struct Limits`

### `fn default_limits() -> Limits`

### `fn open(data: bytes) -> result[Archive, str]`

### `fn open_with(data: bytes, lim: Limits) -> result[Archive, str]`

### `fn read(a: Archive, e: Entry) -> result[bytes, str]`

The entry's contents, inflated and checked against its size and CRC-32.

### `fn find(a: Archive, name: str) -> opt[Entry]`

The entry named `name` exactly, if there is one.

### `fn safe_path(name: str) -> result[str, str]`

A name made safe to join under an extraction directory: relative, with no "..", no drive letter or backslash, no NUL. A trailing "/" is kept. err names what is wrong; extracting such a name is how an archive writes outside the directory ("zip slip").

### `gc struct Writer`

### `fn new_writer() -> Writer`

### `fn add(self: Writer, name: str, data: bytes, modified: int) -> Writer`

Adds a file, deflated (stored instead when deflating does not make it smaller). `modified` is Unix seconds.

### `fn add_stored(self: Writer, name: str, data: bytes, modified: int) -> Writer`

Adds a file as is: for data that is already compressed.

### `fn add_dir(self: Writer, name: str, modified: int) -> Writer`

Adds a directory; "/" is appended to the name when missing.

### `fn finish(self: Writer) -> result[bytes, str]`

The whole archive, or the first problem an add ran into.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
