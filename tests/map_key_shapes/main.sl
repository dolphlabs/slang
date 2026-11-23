// Keys whose shapes the map's hash and slot tags must get right: the
// empty string, lengths either side of each eight-byte word, keys that
// differ only after a long shared prefix (or only in their last byte),
// int keys at the extremes, and one-byte bool keys. Each is stored,
// found, updated, deleted and reinserted, with deletes interleaved so
// backward shifts move tagged slots around. Anything wrong prints FAIL.

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn str_keys() -> [str] {
    let ks: [str] = [""];
    let s = "";
    for i in 0..33 {
        s = s + "a";
        push(ks, s);
    }
    let prefix = "https://api.example.com/v1/accounts/0000/items/";
    for i in 0..500 {
        push(ks, prefix + to_str(i));
        push(ks, "k" + to_str(i) + "x");
    }
    push(ks, prefix + "zzzzzzzzzzzzzzzy");
    push(ks, prefix + "zzzzzzzzzzzzzzzz");
    return ks;
}

let ks = str_keys();
let m: map[str]int = {};
for i in 0..len(ks) {
    m[ks[i]] = i;
}
if len(m) != len(ks) {
    fail("str size " + to_str(len(m)));
}
for i in 0..len(ks) {
    // a separately built copy, so the lookup compares bytes
    let k = "" + ks[i];
    if !has(m, k) || m[k] != i {
        fail("str lookup " + to_str(i));
    }
}
if has(m, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") || has(m, "k500x") {
    fail("str phantom key");
}
for i in 0..len(ks) {
    if i % 3 == 0 {
        del(m, ks[i]);
    }
}
for i in 0..len(ks) {
    let want = i % 3 != 0;
    if has(m, ks[i]) != want {
        fail("str after delete " + to_str(i));
    }
    if want && m[ks[i]] != i {
        fail("str value after delete " + to_str(i));
    }
}
for i in 0..len(ks) {
    m[ks[i]] = i * 2;
}
let sum = 0;
let seen = 0;
for k, v in m {
    if v != m[k] {
        fail("str iteration value");
    }
    sum += v;
    seen += 1;
}
if seen != len(ks) {
    fail("str iteration count " + to_str(seen));
}
println("str keys ok " + to_str(len(m)) + " " + to_str(sum));

let ints: [int] = [0, 1, -1, 9223372036854775807, -9223372036854775807 - 1,
                   4294967296, -4294967296, 256, 65536];
for i in 1..2001 {
    push(ints, i * 1048576);
}
let im: map[int]int = {};
for i in 0..len(ints) {
    im[ints[i]] = i;
}
if len(im) != len(ints) {
    fail("int size " + to_str(len(im)));
}
for i in 0..len(ints) {
    if !has(im, ints[i]) || im[ints[i]] != i {
        fail("int lookup " + to_str(i));
    }
}
for i in 0..len(ints) {
    if i % 2 == 1 {
        del(im, ints[i]);
    }
}
for i in 0..len(ints) {
    if has(im, ints[i]) != (i % 2 == 0) {
        fail("int after delete " + to_str(i));
    }
}
if has(im, 3) || has(im, -2) {
    fail("int phantom key");
}
println("int keys ok " + to_str(len(im)));

let bm: map[bool]int = {};
bm[true] = 1;
bm[false] = 2;
bm[true] = 3;
if len(bm) != 2 || bm[true] != 3 || bm[false] != 2 {
    fail("bool keys");
}
del(bm, true);
if has(bm, true) || !has(bm, false) {
    fail("bool delete");
}
println("bool keys ok");
