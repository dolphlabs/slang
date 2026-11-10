# csv

> Package csv.

CSV (RFC 4180): read a whole document or stream a large one, and write.

```slang
import "csv";

let r = csv.parse("name,qty\n\"Smith, J\",3\n");   // result[[[str]], str]
guard let rows = r else let e = err_of(r) { panic(e); }
csv.to_maps(rows);                                     // the header row as keys: [map[str]str]

let o = csv.options();
o.sep = 9;                                             // TSV
o.comment = 35;                                        // skip lines starting with #
csv.parse_with(text, o);

// streaming: feed what you read, take the records that are whole
let rd = csv.new_reader(csv.options());
csv.feed(rd, chunk);                                   // as often as needed
let nr = csv.next(rd);                                 // result[opt[[str]], str]; none: feed more
csv.end(rd);                                           // then next() returns what remains

csv.format(rows);                                      // CRLF, quoted only where needed
let w = csv.write_options();
w.spreadsheet_safe = true;                             // '=1+1 stays text in a spreadsheet
csv.format_with(rows, w);
```

Quoted fields may hold separators, doubled quotes and line breaks.
Line endings are CRLF or LF, and empty lines are skipped. Errors name
the line: `csv: line 12: text after a closing quote`.

**Strictness.** A quote inside an unquoted field, or text after a closing
quote, is refused unless `lazy_quotes` is set, which reads them as data,
as Go's `LazyQuotes` does. By default every record must be as wide as
the first; set `fields_per_record` to a fixed width, or -1 to allow any.

**Limits.** The input decides how big things get, so `max_field` (1 MiB),
`max_record` (16 MiB) and `max_fields` (4096) bound it. A record still
incomplete past `max_record` is refused without buffering more.

**Streaming** keeps one record's worth of input. Fed chunks are joined
only when a record needs them, and a record far larger than one chunk is
rescanned O(log n) times, not once per chunk. There are no callbacks:
slang has no closures, so the caller does the reading and the reader
only parses.

**Writing.** A field is quoted when it holds the separator, the quote or
a line break, or begins with a space or tab. A record of one empty field
is written as `""`, so it does not read back as an empty line.
`spreadsheet_safe` prefixes fields beginning with `=`, `+`, `-`, `@`,
tab or CR with `'`. That keeps a spreadsheet from running them as
formulas (CSV injection), but it changes the data, so use it only for
files meant for spreadsheets.

**Cost.** The byte scan is native (`encoding.csv_record`); the package
assembles fields. On an 8 MB, 120,000-row file, streaming took about
105 ms against about 33 ms for Go's `encoding/csv` record loop; the rest
is one string per field. `parse` holds every field at once, which is
slower again on large inputs (about 650 ms here), so stream big files.

## API

### `gc struct Options`

### `fn options() -> Options`

Comma-separated, double-quoted, strict quotes, empty lines skipped, every record as wide as the first; a field up to 1 MiB, a record up to 16 MiB and 4096 fields.

### `gc struct Reader`

### `fn parse(text: str) -> result[[[str]], str]`

The whole input with the default options.

### `fn parse_with(text: str, o: Options) -> result[[[str]], str]`

### `fn parse_bytes(data: bytes, o: Options) -> result[[[str]], str]`

### `fn new_reader(o: Options) -> Reader`

A reader to feed: records come out of next as they become whole.

### `fn feed(r: Reader, chunk: bytes)`

More input. Nothing is copied until a record needs it.

### `fn end(r: Reader)`

The input is over: next returns what remains, the last record without its line ending included.

### `fn finished(r: Reader) -> bool`

Every record has been returned and the input has ended.

### `fn line(r: Reader) -> int`

The line the next record starts on (for messages of the caller's own).

### `fn next(r: Reader) -> result[opt[[str]], str]`

The next whole record; none when it needs more input (feed, or end) or when the input is finished.

### `fn to_maps(rows: [[str]]) -> result[[map[str]str], str]`

The first row as the header, each later row as a map from it. A duplicate or empty header name is an error, as is a row of another width.

### `gc struct WriteOptions`

### `fn write_options() -> WriteOptions`

### `fn format(rows: [[str]]) -> str`

Every row as CSV, with the default write options.

### `fn format_with(rows: [[str]], o: WriteOptions) -> str`

### `fn write_row(out: builder.Str, row: [str], o: WriteOptions)`

Appends one record to out: for output built a row at a time.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
