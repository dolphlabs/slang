import "json";

struct ValUser {
    user_id: int `db:"id" json:"userId"`,
    full_name: str `json:"full-name,omitempty"`,
    dash_key: str `json:"-,"`,
    internal_note: str `json:"-"`,
}

gc struct GcItem {
    item_id: i32 `json:"itemId"`,
    opt_label: opt[str] `json:"optLabel,omitempty"`,
    text_val: str `json:"textVal,omitempty"`,
    raw_bytes: bytes `json:"rawBytes,omitempty"`,
    tags: [str] `json:"tags,omitempty"`,
    meta: map[str]int `json:"meta,omitempty"`,
    active: bool `json:"active,omitempty"`,
    score: int `json:"score,omitempty"`,
    ratio: float `json:"ratio,omitempty"`,
    secret_tok: str `json:"-"`,
    opt_extra: opt[str] `json:"-"`,
    flag_skip: bool `json:"-"`,
    buf_skip: bytes `json:"-"`,
}

gc struct SkipAndChan {
    ch: chan[int] `json:"-"`,
    visible_name: str `json:"visibleName"`,
}

struct AllSkipped {
    a: int `json:"-"`,
    b: str `json:"-"`,
}

struct Envelope[T] {
    ok_flag: bool `json:"ok,omitempty"`,
    payload: T `json:"data"`,
}

fn contains(hay: str, needle: str) -> bool {
    let h = to_bytes(hay);
    let n = to_bytes(needle);
    if len(n) == 0 { return true; }
    if len(n) > len(h) { return false; }
    let i = 0;
    while i <= len(h) - len(n) {
        let j = 0;
        let ok = true;
        while j < len(n) {
            if h[i + j] != n[j] {
                ok = false;
                break;
            }
            j += 1;
        }
        if ok { return true; }
        i += 1;
    }
    return false;
}

// 1. Value struct rename, non-json tag ignored, literal "-", omitempty first/middle, skip
let vu_empty_name = ValUser {
    user_id: 7,
    full_name: "",
    dash_key: "d",
    internal_note: "secret",
};
println(json.encode(vu_empty_name));

let vu_full = ValUser {
    user_id: 9,
    full_name: "Ada",
    dash_key: "x",
    internal_note: "hidden",
};
let vu_json = json.encode(vu_full);
println(vu_json);

let r_vu: result[ValUser, str] = json.decode("{\"-\":\"dd\",\"ignored\":123,\"userId\":42,\"full-name\":\"Grace\",\"internal_note\":\"evil\"}");
guard let vu_dec = r_vu else |e| { panic("vu dec: " + e); }
println("${vu_dec.user_id}:${vu_dec.full_name}:${vu_dec.dash_key}:${len(vu_dec.internal_note)}");

// 2. All omitempty empty vs populated on gc struct
let empty_tags: [str] = [];
let empty_meta: map[str]int = {};
let item_empty = GcItem {
    item_id: 1,
    opt_label: none,
    text_val: "",
    raw_bytes: b"",
    tags: empty_tags,
    meta: empty_meta,
    active: false,
    score: 0,
    ratio: 0.0,
    secret_tok: "s",
    opt_extra: some("x"),
    flag_skip: true,
    buf_skip: b"abc",
};
println(json.encode(item_empty));

let item_full = GcItem {
    item_id: 2,
    opt_label: some("lbl"),
    text_val: "hi",
    raw_bytes: b"ok",
    tags: ["a", "b"],
    meta: {"k": 5},
    active: true,
    score: 10,
    ratio: 1.5,
    secret_tok: "s2",
    opt_extra: none,
    flag_skip: true,
    buf_skip: b"z",
};
let item_full_json = json.encode(item_full);
println(item_full_json);

let r_item: result[GcItem, str] = json.decode(item_full_json);
guard let item_dec = r_item else |e| { panic("item dec: " + e); }
let lbl_s = item_dec.opt_label ?? "none";
let extra_s = item_dec.opt_extra ?? "none";
let meta_k = item_dec.meta["k"];
println("${item_dec.item_id}:${lbl_s}:${item_dec.text_val}:${len(item_dec.raw_bytes)}:${len(item_dec.tags)}:${meta_k}:${item_dec.active}:${item_dec.score}:${len(item_dec.secret_tok)}:${extra_s}:${item_dec.flag_skip}:${len(item_dec.buf_skip)}");

// 3. Skip non-JSON chan field on encode
let sc = SkipAndChan { ch: make_chan(1), visible_name: "chanok" };
println(json.encode(sc));

// 4. All fields skipped
let all_sk = AllSkipped { a: 5, b: "x" };
println(json.encode(all_sk));
let r_sk: result[AllSkipped, str] = json.decode("{\"a\":99,\"extra\":[1,2]}");
guard let sk_dec = r_sk else |e| { panic("all_sk: " + e); }
println("${sk_dec.a}:${len(sk_dec.b)}");

// 5. Generic struct with tags (both empty and non-empty omitempty)
let env1 = Envelope { ok_flag: false, payload: ValUser { user_id: 3, full_name: "", dash_key: "k", internal_note: "n" } };
let env2 = Envelope { ok_flag: true, payload: ValUser { user_id: 4, full_name: "Bo", dash_key: "m", internal_note: "n" } };
println(json.encode(env1));
println(json.encode(env2));
let r_env: result[Envelope[ValUser], str] = json.decode(json.encode(env2));
guard let env_dec = r_env else |e| { panic("env dec: " + e); }
println("${env_dec.ok_flag}:${env_dec.payload.user_id}:${env_dec.payload.dash_key}");

// 6. Tree-decoder error paths report wire key name
let r_miss: result[ValUser, str] = json.decode("{\"-\":\"x\"}");
if let _v = r_miss { panic("expected missing error"); } else |e| {
    assert(contains(e, "userId"), "missing err should name wire key userId, got: " + e);
    println("miss_wire_ok");
}

let r_bad: result[ValUser, str] = json.decode("{\"userId\":\"notanint\",\"-\":\"x\"}");
if let _v = r_bad { panic("expected type error"); } else |e| {
    assert(contains(e, "userId"), "bad err should name wire key userId, got: " + e);
    println("bad_wire_ok");
}

// 7. GC stress with tagged structs
let total = 0;
for i in 1..300 {
    let g = GcItem {
        item_id: i as i32,
        opt_label: some("item-" + to_str(i)),
        text_val: "v",
        raw_bytes: b"xy",
        tags: ["t1", "t2"],
        meta: {"n": i},
        active: true,
        score: i,
        ratio: 2.0,
        secret_tok: "drop",
        opt_extra: some("e"),
        flag_skip: false,
        buf_skip: b"q",
    };
    let enc = json.encode(g);
    let dr: result[GcItem, str] = json.decode(enc);
    guard let back = dr else |e| { panic(e); }
    total += back.score;
}
println(total);
