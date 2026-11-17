// Unit tests: `slangc test stdlib/yaml`. Parity with ruamel.yaml over
// generated streams is tests/yaml_parity.

import "strings";

struct Port {
    name: str,
    port: int,
}

struct Container {
    name: str,
    image: str,
    args: [str],
    ports: [Port],
    debug: opt[bool],
}

gc struct Deployment {
    kind: str,
    replicas: int,
    labels: map[str]str,
    containers: [Container],
    note: str,
}

struct Doc {
    n: int,
}

fn json_of(text: str) -> str {
    let r = to_json(text);
    guard let j = r else let e = err_of(r) { panic(e); }
    return j;
}

fn err_text(text: str) -> str {
    let r = to_json_all(text);
    guard let js = r else let e = err_of(r) { return e; }
    panic("parsed: " + strings.join(js, " | "));
}

fn test_should_decode_a_config_into_structs() {
    let doc = "kind: Deployment\nreplicas: 3\nlabels:\n  app: api\n  tier: \"1\"\ncontainers:\n" +
              "  - name: web\n    image: nginx:1.27\n    args: [--port, \"8080\"]\n    ports:\n" +
              "      - {name: http, port: 8080}\n  - name: sidecar\n    image: envoy\n    args: []\n" +
              "    ports: []\n    debug: true\nnote: |\n  two\n  lines\n";
    let r: result[Deployment, str] = decode(doc);
    guard let d = r else let e = err_of(r) { panic(e); }
    assert(d.kind == "Deployment" && d.replicas == 3, "scalars");
    assert(d.labels["tier"] == "1", "a quoted number is a string");
    assert(len(d.containers) == 2 && d.containers[0].image == "nginx:1.27", "a colon inside a plain value");
    assert(d.containers[0].args[1] == "8080" && d.containers[0].ports[0].port == 8080, "flow collections");
    assert((d.containers[0].debug ?? true) && (d.containers[1].debug ?? false), "a missing key is none");
    assert(d.note == "two\nlines\n", "a literal block scalar");
}

fn test_should_decode_every_document() {
    let r: result[[Doc], str] = decode_all("n: 1\n---\nn: 2\n...\n---\nn: 3\n");
    guard let ds = r else let e = err_of(r) { panic(e); }
    assert(len(ds) == 3 && ds[2].n == 3, "three documents");
    let one: result[Doc, str] = decode("n: 1\n---\nn: 2\n");
    guard let _d = one else let e = err_of(one) {
        assert(strings.contains(e, "2 documents"), e);
        return;
    }
    panic("decode read two documents as one");
}

fn test_should_resolve_plain_scalars_by_the_core_schema() {
    assert(json_of("a: yes\nb: no\nc: on\nd: Off\n") == "{\"a\":\"yes\",\"b\":\"no\",\"c\":\"on\",\"d\":\"Off\"}", "1.1 booleans are strings");
    assert(json_of("a: true\nb: FALSE\nc: ~\nd: null\ne:\n") == "{\"a\":true,\"b\":false,\"c\":null,\"d\":null,\"e\":null}", "bool and null");
    assert(json_of("a: 012\nb: 0o17\nc: 0x1F\nd: -3\ne: +4\n") == "{\"a\":12,\"b\":15,\"c\":31,\"d\":-3,\"e\":4}", "ints");
    assert(json_of("a: .5\nb: 1.\nc: 1e3\nd: .inf\ne: .NaN\n") == "{\"a\":0.5,\"b\":1,\"c\":1000,\"d\":null,\"e\":null}", "floats");
    assert(json_of("a: 1_000\nb: 0b1\nc: 1:30\nd: 2024-01-02\n") ==
           "{\"a\":\"1_000\",\"b\":\"0b1\",\"c\":\"1:30\",\"d\":\"2024-01-02\"}", "not numbers in YAML 1.2");
    assert(json_of("a: !!str 12\nb: !!float 1\n") == "{\"a\":\"12\",\"b\":1}", "core tags");
}

fn test_should_read_block_scalars() {
    assert(json_of("a: |\n  x\n  y\n\nb: 1\n") == "{\"a\":\"x\\ny\\n\",\"b\":1}", "literal, clipped");
    assert(json_of("a: >\n  x\n  y\n\n  z\n") == "{\"a\":\"x y\\nz\\n\"}", "folded");
    assert(json_of("a: |-\n  x\n\n") == "{\"a\":\"x\"}", "stripped");
    assert(json_of("a: |+\n  x\n\n") == "{\"a\":\"x\\n\\n\"}", "kept");
    assert(json_of("a: >\n  x\n    more\n  y\n") == "{\"a\":\"x\\n  more\\ny\\n\"}", "more-indented lines keep their breaks");
}

fn test_should_merge_keys_and_share_aliases() {
    let doc = "base: &b\n  timeout: 30\n  retries: 3\nprod:\n  <<: *b\n  retries: 5\nlist: &l [1, 2]\nagain: *l\n";
    assert(json_of(doc) == "{\"base\":{\"timeout\":30,\"retries\":3},\"prod\":{\"timeout\":30,\"retries\":5}," +
                           "\"list\":[1,2],\"again\":[1,2]}", json_of(doc));
}

fn test_should_name_the_line_of_an_error() {
    let e = err_text("a: 1\nb: 2\na: 3\n");
    assert(e == "yaml: line 3: key \"a\" is defined more than once", e);
    let e2 = err_text("a:\n  b: 1\n c: 2\n");
    assert(strings.has_prefix(e2, "yaml: line 3: "), e2);
    let e3 = err_text("a:\n\tb: 1\n");
    assert(e3 == "yaml: line 2: a tab in indentation", e3);
    let e4 = err_text("a: *missing\n");
    assert(e4 == "yaml: line 1: an alias to an unknown anchor *missing", e4);
    let e5 = err_text("a: !custom x\n");
    assert(strings.contains(e5, "tag !custom is not supported"), e5);
    let e6 = err_text("--- &a x\n--- *a\n");
    assert(strings.contains(e6, "unknown anchor *a"), "anchors belong to their document: " + e6);
}

fn test_should_refuse_what_is_not_supported() {
    let bad = ["? key\n: v\n", "[a]: b\n", "a: &x [*x]\n", "%TAG ! tag:x,2000:\n---\na: 1\n", "a: b: c\n",
               "a: \"\\uD800\"\n", "a: 99999999999999999999\n"];
    for doc in bad {
        let r = to_json_all(doc);
        guard let js = r else { continue; }
        panic("accepted " + doc + " as " + strings.join(js, " | "));
    }
}

fn test_should_stop_alias_expansion() {
    // nine levels of nine aliases: 9^9 nodes if expanded
    let b = "a: &a [x, x, x, x, x, x, x, x, x]\n";
    let prev = "a";
    let names = ["b", "c", "d", "e", "f", "g", "h", "i"];
    for nm in names {
        b = b + nm + ": &" + nm + " [*" + prev + ", *" + prev + ", *" + prev + ", *" + prev + ", *" + prev + ", *" +
            prev + ", *" + prev + ", *" + prev + ", *" + prev + "]\n";
        prev = nm;
    }
    let e = err_text(b);
    assert(strings.contains(e, "aliases expand to more than"), e);
}

fn test_should_limit_nesting() {
    let deep = strings.repeat("[", 300) + strings.repeat("]", 300);
    let e = err_text("a: " + deep + "\n");
    assert(strings.contains(e, "nested more than 256 levels"), e);
}
