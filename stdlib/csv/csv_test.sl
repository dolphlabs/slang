// Unit tests: `slangc test stdlib/csv`. Parity with Python's csv module
// over generated documents is tests/csv_parity.

import "builder";
import "strings";

fn rows_of(text: str) -> [[str]] {
    let r = parse(text);
    guard let rows = r else let e = err_of(r) { panic(e); }
    return rows;
}

fn show(rows: [[str]]) -> str {
    let parts: [str] = [];
    for row in rows {
        push(parts, "[" + strings.join(row, "|") + "]");
    }
    return strings.join(parts, "");
}

fn parse_err(text: str, o: Options) -> str {
    let r = parse_with(text, o);
    guard let rows = r else let e = err_of(r) { return e; }
    panic("parsed: " + show(rows));
}

fn test_should_read_rfc_4180_records() {
    assert(show(rows_of("a,b,c\r\n1,2,3\r\n")) == "[a|b|c][1|2|3]", "crlf");
    assert(show(rows_of("a,b\n1,2")) == "[a|b][1|2]", "lf, no final newline");
    assert(show(rows_of("\"Smith, J\",\"say \"\"hi\"\"\",\"two\nlines\"\n")) == "[Smith, J|say \"hi\"|two\nlines]", "quoted");
    assert(show(rows_of("a,,c\n,,\n")) == "[a||c][||]", "empty fields");
    assert(show(rows_of("\"\",x\n")) == "[|x]", "an empty quoted field");
    assert(show(rows_of("a\r\n\r\n\nb\r\n")) == "[a][b]", "empty lines skipped");
    assert(show(rows_of("a\rb,c\n")) == "[a\rb|c]", "a CR not before LF is data");
    assert(show(rows_of("x,y\r")) == "[x|y]", "a CR at the very end");
    assert(len(rows_of("")) == 0, "nothing");
    assert(show(rows_of("é,☃\n")) == "[é|☃]", "utf-8");
}

fn test_should_honour_separator_comments_and_empty_lines() {
    let o = options();
    o.sep = 9;
    o.comment = 35;
    assert(show(parse_with("# a comment\na\tb\n#another\nc\td\n", o) ?? []) == "[a|b][c|d]", "tsv with comments");
    let keep = options();
    keep.skip_empty = false;
    assert(show(parse_with("a\n\nb\n", keep) ?? []) == "[a][][b]", show(parse_with("a\n\nb\n", keep) ?? []));
    let anyw = options();
    anyw.fields_per_record = -1;
    assert(show(parse_with("a\nb,c\n", anyw) ?? []) == "[a][b|c]", "ragged allowed");
}

fn test_should_refuse_malformed_input_with_its_line() {
    let o = options();
    assert(parse_err("a,b\nc,d\"e\n", o) == "csv: line 2: a quote inside an unquoted field (lazy_quotes reads it as data)",
           parse_err("a,b\nc,d\"e\n", o));
    assert(parse_err("a\n\"x\"y,z\n", o) == "csv: line 2: text after a closing quote", parse_err("a\n\"x\"y,z\n", o));
    assert(parse_err("a\n\"open\nstill open", o) == "csv: line 2: a quoted field that is never closed",
           parse_err("a\n\"open\nstill open", o));
    assert(parse_err("a,b\n\"x\ny\",z\nq\n", o) == "csv: line 4: 1 fields where the records have 2",
           parse_err("a,b\n\"x\ny\",z\nq\n", o));
    let lazy = options();
    lazy.lazy_quotes = true;
    assert(show(parse_with("a\"b,\"c\"d\n", lazy) ?? []) == "[a\"b|c\"d]", "lazy quotes");
    let fixed = options();
    fixed.fields_per_record = 3;
    assert(strings.contains(parse_err("a,b\n", fixed), "2 fields where the records have 3"), "fixed width");
}

fn test_should_enforce_limits() {
    let o = options();
    o.max_field = 4;
    assert(strings.contains(parse_err("abcd,abcde\n", o), "field 2 is over 4 bytes"), "field");
    let f = options();
    f.max_fields = 3;
    assert(strings.contains(parse_err("a,b,c,d\n", f), "more than 3 fields"), "fields");
    let r = options();
    r.max_record = 10;
    assert(strings.contains(parse_err("0123456789abc\n", r), "a record over 10 bytes"), "record");
    let bad = options();
    bad.sep = 34;
    assert(strings.contains(err_of(parse_with("a", bad)), "separator"), "sep == quote");
}

// Feeds text step bytes at a time, taking records as they become whole.
fn read_fed(text: str, step: int) -> str {
    let data = to_bytes(text);
    let rd = new_reader(options());
    let out: [[str]] = [];
    let at = 0;
    while true {
        let k = step;
        if at + k > len(data) {
            k = len(data) - at;
        }
        if k == 0 {
            end(rd);
        } else {
            feed(rd, data[at..at + k]);
            at += k;
        }
        while true {
            let nr = next(rd);
            guard let got = nr else let e = err_of(nr) { return "ERR " + e; }
            guard let rec = got else { break; }
            push(out, rec);
        }
        if k == 0 {
            break;
        }
    }
    assert(finished(rd), "finished");
    return show(out);
}

fn test_should_stream_across_every_read_boundary() {
    let text = "id,note\r\n1,\"multi\r\nline, with \"\"quotes\"\"\"\r\n2,plain\r\n\r\n3,\"\"\r\n";
    let whole = show(rows_of(text));
    assert(whole == "[id|note][1|multi\r\nline, with \"quotes\"][2|plain][3|]", whole);
    for step in [1, 2, 3, 5, 7, 64] {
        assert(read_fed(text, step) == whole, "step " + to_str(step) + ": " + read_fed(text, step));
    }
    assert(read_fed("a\nb\"c\n", 1) == "ERR csv: line 2: a quote inside an unquoted field (lazy_quotes reads it as data)",
           "error while streaming");
    let rd = new_reader(options());
    feed(rd, b"a\nb\"c\n");
    next(rd);
    assert(strings.contains(err_of(next(rd)), "line 2"), "the error sticks");
}

fn test_should_stream_a_record_far_larger_than_one_feed() {
    let big = strings.repeat("x", 300000);
    let got = read_fed("a,\"" + big + "\"\nb,c\n", 4096);
    assert(len(got) == 300000 + 9 && strings.has_suffix(got, "][b|c]"), to_str(len(got)));
}

fn test_should_map_rows_by_header() {
    let mr = to_maps(rows_of("name,qty\nink,3\npen,12\n"));
    guard let maps = mr else let e = err_of(mr) { panic(e); }
    assert(len(maps) == 2 && maps[1]["name"] == "pen" && maps[0]["qty"] == "3", "maps");
    assert(strings.contains(err_of(to_maps(rows_of("a,a\n1,2\n"))), "appears twice"), "duplicate header");
    let anyw = options();
    anyw.fields_per_record = -1;
    assert(strings.contains(err_of(to_maps(parse_with("a,b\n1\n", anyw) ?? [])), "row 2 has 1 fields"), "ragged");
}

fn test_should_write_what_it_reads() {
    let rows: [[str]] = [["plain", "with,comma", "with \"quote\"", "two\nlines", " lead", ""], [""], ["x"]];
    let text = format(rows);
    assert(text == "plain,\"with,comma\",\"with \"\"quote\"\"\",\"two\nlines\",\" lead\",\r\n\"\"\r\nx\r\n", text);
    let anyw = options();
    anyw.fields_per_record = -1;
    assert(show(parse_with(text, anyw) ?? []) == show(rows), "round trip");
    let o = write_options();
    o.crlf = false;
    o.sep = 59;
    o.quote_all = true;
    assert(format_with([["a", "b;c"]], o) == "\"a\";\"b;c\"\n", format_with([["a", "b;c"]], o));
    let safe = write_options();
    safe.spreadsheet_safe = true;
    assert(format_with([["=1+1", "+x", "-2", "@SUM(A1)", "ok"]], safe) == "'=1+1,'+x,'-2,'@SUM(A1),ok\r\n",
           format_with([["=1+1", "+x", "-2", "@SUM(A1)", "ok"]], safe));
    let out = builder.new_str();
    write_row(out, ["a", "b"], write_options());
    write_row(out, ["c", "d"], write_options());
    assert(out.finish() == "a,b\r\nc,d\r\n", "row at a time");
}
