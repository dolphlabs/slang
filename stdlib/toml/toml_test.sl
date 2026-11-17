// Unit tests: `slangc test stdlib/toml`. Parity with Python's tomllib
// over generated documents is tests/toml_parity.

import "strings";
import "timez";

struct Db {
    host: str,
    port: int,
    replicas: [str],
    timeout_ms: opt[int],
}

struct Service {
    name: str,
    weight: float,
}

gc struct Config {
    name: str,
    debug: bool,
    started: timez.Time,
    db: Db,
    services: [Service],
    labels: map[str]str,
}

fn json_of(text: str) -> str {
    let r = to_json(text);
    guard let j = r else let e = err_of(r) { panic(e); }
    return j;
}

fn err_text(text: str) -> str {
    let r = to_json(text);
    guard let j = r else let e = err_of(r) { return e; }
    panic("parsed: " + j);
}

fn test_should_decode_a_config_into_structs() {
    let doc = "name = \"api\"\ndebug = false\nstarted = 2026-11-17T09:30:00Z\n\n[db]\nhost = \"db.internal\"\n" +
              "port = 5432\nreplicas = [\"r1\", \"r2\"]\n\n[[services]]\nname = \"auth\"\nweight = 0.5\n\n" +
              "[[services]]\nname = \"billing\"\nweight = 2\n\n[labels]\nteam = \"core\"\n\"tier.1\" = \"gold\"\n";
    let r: result[Config, str] = decode(doc);
    guard let c = r else let e = err_of(r) { panic(e); }
    assert(c.name == "api" && !c.debug, "top level");
    assert(c.db.host == "db.internal" && c.db.port == 5432, "table");
    assert(len(c.db.replicas) == 2 && c.db.replicas[1] == "r2", "array");
    assert((c.db.timeout_ms ?? -1) == -1, "a missing key is none");
    assert(len(c.services) == 2 && c.services[1].name == "billing" && c.services[1].weight == 2.0, "array of tables");
    assert(c.labels["tier.1"] == "gold", "a quoted key with a dot");
    assert(c.started.rfc3339() == "2026-11-17T09:30:00Z", "an offset date-time into a time field");
}

fn test_should_report_a_type_mismatch_from_decode() {
    let r: result[Db, str] = decode("host = \"h\"\nport = \"5432\"\nreplicas = []\n");
    guard let _d = r else let e = err_of(r) {
        assert(strings.has_prefix(e, "toml: "), e);
        return;
    }
    panic("a string port decoded");
}

fn test_should_write_tables_in_document_order() {
    assert(json_of("b = 1\na = 2\n[z]\n[y]\n") == "{\"b\":1,\"a\":2,\"z\":{},\"y\":{}}", "order");
    assert(json_of("[x.y.z]\n[x]\nk = 1\n") == "{\"x\":{\"y\":{\"z\":{}},\"k\":1}}", "a super-table after");
    assert(json_of("") == "{}", "empty");
}

fn test_should_convert_values() {
    assert(json_of("a = 0xff\nb = 0o17\nc = 0b101\nd = 1_000\ne = -0\n") == "{\"a\":255,\"b\":15,\"c\":5,\"d\":1000,\"e\":0}", "ints");
    assert(json_of("a = 1.5\nb = 3.0\nc = 1e3\nd = -2.5E-3\n") == "{\"a\":1.5,\"b\":3,\"c\":1000,\"d\":-0.0025}", "floats");
    assert(json_of("a = inf\nb = -nan\n") == "{\"a\":null,\"b\":null}", "inf and nan have no JSON");
    assert(json_of("a = 1979-05-27 07:32:00z\n") == "{\"a\":\"1979-05-27T07:32:00Z\"}", "space and z become T and Z");
    assert(json_of("a = 1979-05-27T07:32:00.5\nb = 1979-05-27\nc = 07:32:00\n") ==
           "{\"a\":\"1979-05-27T07:32:00.5\",\"b\":\"1979-05-27\",\"c\":\"07:32:00\"}", "local date-times as written");
    assert(json_of("a = \"tab\\there \\u00e9 \\U0001F600 \\\"q\\\"\"\n") == "{\"a\":\"tab\\there é 😀 \\\"q\\\"\"}", "escapes");
    assert(json_of("a = \"\\u0000\"\n") == "{\"a\":\"\\u0000\"}", "U+0000 survives as an escape");
    assert(json_of("a = 'C:\\path\\x'\n") == "{\"a\":\"C:\\\\path\\\\x\"}", "literal backslashes");
    assert(json_of("a = '''\nit's\r\nhere'''\n") == "{\"a\":\"it's\\nhere\"}", "a lone quote and CRLF in a multi-line literal");
}

fn test_should_name_the_line_of_an_error() {
    let e = err_text("a = 1\nb = 2\na = 3\n");
    assert(e == "toml: line 3: key \"a\" is defined more than once", e);
    let e2 = err_text("[t]\nx = 1\n\n[t]\n");
    assert(e2 == "toml: line 4: table \"t\" is defined more than once", e2);
    let e3 = err_text("x = [1,\n2,\n");
    assert(strings.has_prefix(e3, "toml: line 3: "), e3);
    let e4 = err_text("n = 9223372036854775808\n");
    assert(e4 == "toml: line 1: an integer outside 64 bits 9223372036854775808", e4);
    let e5 = err_text("[fruit]\napple.color = \"red\"\n[fruit.apple]\n");
    assert(e5 == "toml: line 3: table \"apple\" is defined more than once", e5);
}

fn test_should_refuse_what_the_spec_forbids() {
    let bad = ["a = 1 b = 2", "a = 01", "a = 1__0", "a = 1979-02-30", "a = { b = 1, }", "t = { a = 1 }\nt.b = 2",
               "a = \"x\ny\"", "a = 1\rb = 2", "[a]\n[[a]]", "a = []\n[[a]]", "a = \"\\q\"", "a = \"\\uD800\""];
    for doc in bad {
        let r = to_json(doc);
        guard let j = r else { continue; }
        panic("accepted " + doc + " as " + j);
    }
}

fn test_should_limit_nesting() {
    let deep = strings.repeat("[", 300) + strings.repeat("]", 300);
    let e = err_text("a = " + deep);
    assert(strings.contains(e, "nested more than 256 levels"), e);
    let ok_deep = strings.repeat("[", 200) + strings.repeat("]", 200);
    let r = to_json("a = " + ok_deep);
    guard let _j = r else let e2 = err_of(r) { panic(e2); }
}
