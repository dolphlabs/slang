// json.decode reads input straight into the target type and falls back to
// the parse tree only when that fails, for the error. This pins what the
// tree decoder alone used to do, so the fast path can never drift from it:
// which input is accepted, what it decodes to, and every error message,
// including which error wins when there are several.
import "json";
import "strings";

enum Kind {
    Small,
    Large,
}

gc struct Inner {
    city: str,
    zip: opt[str],
}

gc struct Rec {
    id: int,
    name: str,
    tags: [str],
    inner: Inner,
    score: opt[float],
    small: i8,
    flag: bool,
    raw: bytes,
    counts: map[str]int,
    kind: Kind,
}

fn rec(label: str, src: str) {
    let r: result[Rec, str] = json.decode(src);
    guard let v = r else let e = err_of(r) {
        println(label + ": err " + e);
        return;
    }
    println(label + ": ok " + json.encode(v));
}

fn ints(label: str, src: str) {
    let r: result[[[int]], str] = json.decode(src);
    guard let v = r else let e = err_of(r) {
        println(label + ": err " + e);
        return;
    }
    println(label + ": ok " + json.encode(v));
}

fn one(label: str, src: str) {
    let r: result[int, str] = json.decode(src);
    guard let v = r else let e = err_of(r) {
        println(label + ": err " + e);
        return;
    }
    println(label + ": ok " + to_str(v));
}

fn text(label: str, src: str) {
    let r: result[str, str] = json.decode(src);
    guard let v = r else let e = err_of(r) {
        println(label + ": err " + e);
        return;
    }
    println(label + ": ok len=" + to_str(len(v)) + " " + json.encode(v));
}

let base = "\"id\":1,\"name\":\"n\",\"tags\":[\"a\",\"b\"],\"inner\":{\"city\":\"c\"},\"small\":1,\"flag\":true,\"raw\":\"aGk=\",\"counts\":{\"x\":1},\"kind\":\"Small\"";

rec("full", "{" + base + "}");
rec("spaces", " \n\t{ \"id\" : 1 , \"name\" : \"n\" , \"tags\" : [ ] , \"inner\" : { \"city\" : \"c\" , \"zip\" : null } , \"score\" : 2.5 , \"small\" : -128 , \"flag\" : false , \"raw\" : \"\" , \"counts\" : { } , \"kind\" : \"Large\" } \r\n");
rec("reordered", "{\"kind\":\"Large\",\"counts\":{},\"raw\":\"\",\"flag\":false,\"small\":0,\"inner\":{\"zip\":\"z\",\"city\":\"c\"},\"tags\":[],\"name\":\"n\",\"id\":9}");
rec("dup first wins", "{" + base + ",\"id\":2,\"name\":\"second\"}");
rec("dup bad second", "{" + base + ",\"id\":\"not an int\"}");
rec("dup bad syntax second", "{" + base + ",\"id\":[1,}");
rec("unknown keys", "{\"extra\":{\"a\":[1,{\"b\":null}],\"c\":\"\\u00e9\"}," + base + ",\"more\":[true,false,-1.5e3]}");
rec("escaped key", "{\"i\\u0064\":1,\"name\":\"n\",\"tags\":[],\"inner\":{\"city\":\"c\"},\"small\":1,\"flag\":true,\"raw\":\"\",\"counts\":{},\"kind\":\"Small\"}");
rec("nul in key", "{\"id\\u0000zz\":7,\"name\":\"n\",\"tags\":[],\"inner\":{\"city\":\"c\"},\"small\":1,\"flag\":true,\"raw\":\"\",\"counts\":{},\"kind\":\"Small\"}");
rec("map dup last wins", "{" + strings.replace(base, "{\"x\":1}", "{\"a\":1,\"b\":3,\"a\":2}") + "}");
rec("missing required", "{\"name\":\"n\"}");
rec("missing before type", "{\"name\":5}");
rec("type error field order", "{\"kind\":1,\"id\":\"x\",\"name\":\"n\"}");
rec("type then syntax", "{\"id\":\"x\",\"name\":");
rec("null required", "{" + strings.replace(base, "\"id\":1", "\"id\":null") + "}");
rec("int as float", "{" + strings.replace(base, "\"id\":1", "\"id\":1.5") + "}");
rec("int exponent", "{" + strings.replace(base, "\"id\":1", "\"id\":1e3") + "}");
rec("int point zero", "{" + strings.replace(base, "\"id\":1", "\"id\":5.0") + "}");
rec("i8 range", "{" + strings.replace(base, "\"small\":1", "\"small\":128") + "}");
rec("leading zero", "{" + strings.replace(base, "\"id\":1", "\"id\":01") + "}");
rec("minus alone", "{" + strings.replace(base, "\"id\":1", "\"id\":-") + "}");
rec("bad base64", "{" + strings.replace(base, "aGk=", "a=b=") + "}");
rec("bad variant", "{" + strings.replace(base, "Small", "Medium") + "}");
rec("object for list", "{" + strings.replace(base, "[\"a\",\"b\"]", "{}") + "}");
rec("nested error", "{" + strings.replace(base, "{\"city\":\"c\"}", "{\"city\":5}") + "}");
rec("list item error", "{" + strings.replace(base, "[\"a\",\"b\"]", "[\"a\",2]") + "}");
rec("trailing comma obj", "{" + base + ",}");
rec("trailing comma list", "{" + strings.replace(base, "[\"a\",\"b\"]", "[\"a\",]") + "}");
rec("trailing garbage", "{" + base + "} x");
rec("two values", "{" + base + "}{}");
rec("unterminated", "{\"id\":1,\"name\":\"n");
rec("empty", "");
rec("blank", "   ");
rec("bad escape", "{\"id\":1,\"name\":\"\\q\"}");
rec("lone low surrogate", "{\"id\":1,\"name\":\"\\udc00\"}");
rec("unpaired high surrogate", "{\"id\":1,\"name\":\"\\ud83dx\"}");
rec("control char", "{\"id\":1,\"name\":\"a\tb\"}");
rec("literal typo", "{" + strings.replace(base, "true", "tru") + "}");
rec("not an object", "[1]");
ints("nested lists", "[[1,2],[],[3]]");
ints("nested bad", "[[1,2],3]");
one("top int", " 42 ");
one("top int junk", "42x");
one("top neg zero", "-0");
text("surrogate pair", "\"\\ud83d\\ude00\"");
text("utf8 raw", "\"café ☕\"");
text("escaped nul", "\"a\\u0000b\"");
text("escapes", "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"");
