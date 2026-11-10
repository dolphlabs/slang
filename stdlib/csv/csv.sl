// CSV (RFC 4180): reading, whole or streamed, and writing.
//
//     import "csv";
//
//     let r = csv.parse("name,qty\n\"Smith, J\",3\n");    // result[[[str]], str]
//     guard let rows = r else let e = err_of(r) { panic(e); }
//     let mr = csv.to_maps(rows);                        // header row -> [map[str]str]
//
//     // a large file, one record at a time, in bounded memory: feed it
//     // what you read, and take the records that are whole
//     let rd = csv.new_reader(csv.options());
//     while true {
//         let chunk = read_some();                       // fs, a socket, a request body
//         if len(chunk) == 0 { csv.end(rd); } else { csv.feed(rd, chunk); }
//         while true {
//             let nr = csv.next(rd);                     // result[opt[[str]], str]
//             guard let got = nr else let e = err_of(nr) { panic(e); }
//             guard let rec = got else { break; }        // none: feed more (or the end)
//             handle(rec);
//         }
//         if len(chunk) == 0 { break; }
//     }
//
//     csv.format(rows);                                  // CRLF line endings, quoted as needed
//
// Quoted fields may hold separators, doubled quotes and line breaks.
// Line endings are CRLF or LF. Everything the input controls is bounded:
// the size of a field and of a record, and the number of fields. The
// byte scanning is native (encoding.csv_record); this package buffers,
// checks and assembles.

import "builder";
import "encoding";
import "strings";

pub gc struct Options {
    // the field separator, a byte: ',' by default, '\t' for TSV, ';'
    sep: int,
    // the quote byte
    quote: int,
    // accept a quote inside an unquoted field and text after a closing
    // quote, as data, instead of refusing the input
    lazy_quotes: bool,
    // lines starting with this byte are skipped (0: none)
    comment: int,
    // skip lines that are empty (true: the common reading; RFC 4180
    // reads one as a record of one empty field)
    skip_empty: bool,
    // fields every record must have: 0 the first record's count, a
    // positive number exactly that, -1 any
    fields_per_record: int,
    max_field: int,
    max_fields: int,
    max_record: int,
}

// Comma-separated, double-quoted, strict quotes, empty lines skipped,
// every record as wide as the first; a field up to 1 MiB, a record up
// to 16 MiB and 4096 fields.
pub fn options() -> Options {
    return Options { sep: 44, quote: 34, lazy_quotes: false, comment: 0, skip_empty: true,
                     fields_per_record: 0, max_field: 1048576, max_fields: 4096, max_record: 16777216 };
}

pub gc struct Reader {
    opts: Options,
    data: bytes,
    pos: int,
    // fed but not yet joined into data, and their size
    parts: [bytes],
    parts_size: int,
    // an incomplete record waits until this much is buffered: twice what
    // the last scan saw, so a record far larger than one feed is joined
    // and scanned O(log n) times, not once per feed
    need: int,
    eof: bool,
    // the line the next record starts on
    line: int,
    width: int,
    failed: str,
}

// The whole input with the default options.
pub fn parse(text: str) -> result[[[str]], str] {
    return parse_bytes(to_bytes(text), options());
}

pub fn parse_with(text: str, o: Options) -> result[[[str]], str] {
    return parse_bytes(to_bytes(text), o);
}

pub fn parse_bytes(data: bytes, o: Options) -> result[[[str]], str] {
    let cr = check_options(o);
    guard let _c = cr else let e = err_of(cr) { return err(e); }
    let rd = Reader { opts: o, data: data, pos: 0, parts: [], parts_size: 0, need: 0, eof: true, line: 1,
                      width: o.fields_per_record, failed: "" };
    let out: [[str]] = [];
    while true {
        let nr = next(rd);
        guard let got = nr else let e = err_of(nr) { return err(e); }
        guard let rec = got else { break; }
        push(out, rec);
    }
    return ok(out);
}

fn options_error(o: Options) -> str {
    let cr = check_options(o);
    guard let _c = cr else let e = err_of(cr) { return e; }
    return "";
}

fn check_options(o: Options) -> result[bool, str] {
    if o.sep < 0 || o.sep > 255 || o.sep == 10 || o.sep == 13 || o.sep == o.quote {
        return err("csv: the separator must be a byte other than CR, LF and the quote");
    }
    if o.quote < 0 || o.quote > 255 || o.quote == 10 || o.quote == 13 {
        return err("csv: the quote must be a byte other than CR and LF");
    }
    if o.comment == o.sep || o.comment == o.quote || o.comment == 10 || o.comment == 13 {
        return err("csv: the comment byte must differ from the separator, the quote, CR and LF");
    }
    if o.max_field < 1 || o.max_fields < 1 || o.max_record < 1 {
        return err("csv: limits must be positive");
    }
    return ok(true);
}

// A reader to feed: records come out of next as they become whole.
pub fn new_reader(o: Options) -> Reader {
    // bad options are reported by the first next()
    let failed = options_error(o);
    return Reader { opts: o, data: strings.bytes_zero(0), pos: 0, parts: [], parts_size: 0, need: 0, eof: false,
                    line: 1, width: o.fields_per_record, failed: failed };
}

// More input. Nothing is copied until a record needs it.
pub fn feed(r: Reader, chunk: bytes) {
    if len(chunk) > 0 {
        push(r.parts, chunk);
        r.parts_size += len(chunk);
    }
}

// The input is over: next returns what remains, the last record without
// its line ending included.
pub fn end(r: Reader) {
    r.eof = true;
}

// Every record has been returned and the input has ended.
pub fn finished(r: Reader) -> bool {
    return r.eof && r.pos >= len(r.data) && r.parts_size == 0;
}

// The line the next record starts on (for messages of the caller's own).
pub fn line(r: Reader) -> int {
    return r.line;
}

fn fail(r: Reader, line: int, what: str) -> result[opt[[str]], str] {
    r.failed = "csv: line " + to_str(line) + ": " + what;
    return err(r.failed);
}

// Joins what was fed onto the unparsed rest, when there is enough of it
// (or the input has ended).
fn gather(r: Reader) {
    if r.parts_size == 0 {
        return;
    }
    let have = len(r.data) - r.pos;
    if have + r.parts_size < r.need && !r.eof {
        return;
    }
    let all: [bytes] = [];
    if have > 0 {
        push(all, r.data[r.pos..]);
    }
    for p in r.parts {
        push(all, p);
    }
    if len(all) == 1 {
        r.data = all[0];
    } else {
        r.data = strings.join_bytes(all, b"");
    }
    r.pos = 0;
    r.parts = [];
    r.parts_size = 0;
}

// An incomplete record: wait for twice as much before scanning again.
fn wait_more(r: Reader) -> result[opt[[str]], str] {
    let have = len(r.data) - r.pos;
    if have > r.opts.max_record {
        return fail(r, r.line, "a record over " + to_str(r.opts.max_record) + " bytes");
    }
    r.need = have * 2 + 1;
    return ok(none);
}

// The next whole record; none when it needs more input (feed, or end)
// or when the input is finished.
pub fn next(r: Reader) -> result[opt[[str]], str] {
    if r.failed != "" {
        return err(r.failed);
    }
    let o = r.opts;
    while true {
        gather(r);
        if r.pos >= len(r.data) {
            return ok(none);
        }
        let b = r.data;
        let at = r.pos;
        // a comment line, or an empty one
        if (o.comment != 0 && b[at] == o.comment) || (o.skip_empty && is_line_end(b, at)) {
            let lr = encoding.csv_record(b, at, 256, 256, flags(o, r.eof));
            if lr[0] == 1 {
                return wait_more(r);
            }
            r.pos = lr[1];
            r.line += lr[3];
            continue;
        }
        let t = encoding.csv_record(b, at, o.sep, o.quote, flags(o, r.eof));
        let status = t[0];
        if status == 1 {
            return wait_more(r);
        }
        if status == 2 {
            let why = "a quote inside an unquoted field (lazy_quotes reads it as data)";
            if t[2] == 2 {
                why = "text after a closing quote";
            } else if t[2] == 3 {
                why = "a quoted field that is never closed";
            } else if t[2] == 4 {
                why = "out of memory";
            }
            return fail(r, r.line + lines_between(b, at, t[1]), why);
        }
        if status == 3 {
            return ok(none);
        }
        let nf = t[2];
        let line = r.line;
        if t[1] - at > o.max_record {
            return fail(r, line, "a record over " + to_str(o.max_record) + " bytes");
        }
        if nf > o.max_fields {
            return fail(r, line, "more than " + to_str(o.max_fields) + " fields");
        }
        let q = quote_str(o.quote);
        let rec: [str] = [];
        for k in 0..nf {
            let fs = t[4 + 3 * k];
            let fe = t[5 + 3 * k];
            if fe - fs > o.max_field {
                return fail(r, line, "field " + to_str(k + 1) + " is over " + to_str(o.max_field) + " bytes");
            }
            let f = strings.from_bytes(b, fs, fe);
            if t[6 + 3 * k] == 1 {
                f = strings.replace(f, q + q, q);
            }
            push(rec, f);
        }
        r.pos = t[1];
        r.line += t[3];
        r.need = 0;
        if r.width == 0 {
            r.width = nf;
        } else if r.width > 0 && nf != r.width {
            return fail(r, line, to_str(nf) + " fields where the records have " + to_str(r.width));
        }
        return ok(some(rec));
    }
    return ok(none);
}

fn flags(o: Options, eof: bool) -> int {
    let f = 0;
    if o.lazy_quotes {
        f = 1;
    }
    if eof {
        f = f | 2;
    }
    return f;
}

fn is_line_end(b: bytes, at: int) -> bool {
    if b[at] == 10 {
        return true;
    }
    return b[at] == 13 && at + 1 < len(b) && b[at + 1] == 10;
}

// Line endings in b[from..to] (an error's position inside a record).
fn lines_between(b: bytes, from: int, to: int) -> int {
    let n = 0;
    for k in from..to {
        if b[k] == 10 {
            n += 1;
        }
    }
    return n;
}

fn quote_str(q: int) -> str {
    let b = strings.bytes_zero(1);
    b[0] = q;
    return to_str(b);
}

// The first row as the header, each later row as a map from it. A
// duplicate or empty header name is an error, as is a row of another
// width.
pub fn to_maps(rows: [[str]]) -> result[[map[str]str], str] {
    let out: [map[str]str] = [];
    if len(rows) == 0 {
        return ok(out);
    }
    let head = rows[0];
    let seen: map[str]bool = {};
    for h in head {
        if h == "" {
            return err("csv: an empty header name");
        }
        if has(seen, h) {
            return err("csv: header " + h + " appears twice");
        }
        seen[h] = true;
    }
    for k in 1..len(rows) {
        let row = rows[k];
        if len(row) != len(head) {
            return err("csv: row " + to_str(k + 1) + " has " + to_str(len(row)) + " fields, the header " +
                       to_str(len(head)));
        }
        let m: map[str]str = {};
        for j in 0..len(head) {
            m[head[j]] = row[j];
        }
        push(out, m);
    }
    return ok(out);
}

// ---- writing ------------------------------------------------------------------------------

pub gc struct WriteOptions {
    sep: int,
    quote: int,
    // CRLF line endings (RFC 4180); false for LF
    crlf: bool,
    // quote every field, not just those that need it
    quote_all: bool,
    // a field starting with = + - @ tab or CR gets a leading ', so a
    // spreadsheet shows it as text instead of running it as a formula
    // (CSV injection). It changes the data, so it is for files meant to
    // be opened in a spreadsheet.
    spreadsheet_safe: bool,
}

pub fn write_options() -> WriteOptions {
    return WriteOptions { sep: 44, quote: 34, crlf: true, quote_all: false, spreadsheet_safe: false };
}

// Every row as CSV, with the default write options.
pub fn format(rows: [[str]]) -> str {
    return format_with(rows, write_options());
}

pub fn format_with(rows: [[str]], o: WriteOptions) -> str {
    let out = builder.new_str();
    for row in rows {
        write_row(out, row, o);
    }
    return out.finish();
}

// Appends one record to out: for output built a row at a time.
pub fn write_row(out: builder.Str, row: [str], o: WriteOptions) {
    let sep = quote_str(o.sep);
    let q = quote_str(o.quote);
    for k in 0..len(row) {
        if k > 0 {
            out.write(sep);
        }
        let f = row[k];
        if f == "" && len(row) == 1 {
            // alone, an empty field would be an empty line, which readers skip
            out.write(q).write(q);
            continue;
        }
        if o.spreadsheet_safe && formula_like(f) {
            f = "'" + f;
        }
        if o.quote_all || needs_quotes(f, sep, q) {
            out.write(q).write(strings.replace(f, q, q + q)).write(q);
        } else {
            out.write(f);
        }
    }
    if o.crlf {
        out.write("\r\n");
    } else {
        out.write("\n");
    }
}

// A field needs quotes when it holds the separator, the quote, a line
// break, or begins with a space or tab (which some readers trim).
fn needs_quotes(f: str, sep: str, q: str) -> bool {
    if f == "" {
        return false;
    }
    return strings.contains(f, sep) || strings.contains(f, q) || strings.contains(f, "\n") ||
           strings.contains(f, "\r") || strings.has_prefix(f, " ") || strings.has_prefix(f, "\t");
}

fn formula_like(f: str) -> bool {
    return strings.has_prefix(f, "=") || strings.has_prefix(f, "+") || strings.has_prefix(f, "-") ||
           strings.has_prefix(f, "@") || strings.has_prefix(f, "\t") || strings.has_prefix(f, "\r");
}
