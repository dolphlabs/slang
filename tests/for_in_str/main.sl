// for-in over a str reads its bytes in place, with no to_bytes copy:
// `for b in s` gives each byte as an int, and `for i, b in s` the index
// first, as `for i, x in xs` now does for lists and bytes too (two names
// over bytes used to bind the byte to the first name and drop the
// second). The long string's loop allocates on every pass, so a collection
// lands mid-loop under the GC stress runs.

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn count_byte(s: str, want: int) -> int {
    let n = 0;
    for b in s {
        if b == want {
            n += 1;
        }
    }
    return n;
}

let s = "héllo, wörld";
let codes = "";
for b in s {
    codes = codes + to_str(b) + " ";
}
println(codes);
let at = "";
for i, b in s {
    if b == 111 {
        at = at + to_str(i) + " ";
    }
}
println("o at " + at);
println(count_byte(s, 108));

for b in "" {
    fail("an empty str has no bytes");
}

// break and continue
let firsts = "";
for i, b in "abc,def" {
    if b == 44 {
        break;
    }
    if i == 1 {
        continue;
    }
    firsts = firsts + to_str(b) + " ";
}
println(firsts);

// a long str built at run time, with allocation in the loop body
let parts: [str] = [];
for i in 0..2000 {
    push(parts, "k" + to_str(i % 10));
}
let long = "";
for p in parts {
    long = long + p;
}
let kept: [str] = [];
let digits = 0;
let last = -1;
for i, b in long {
    if b >= 48 && b <= 57 {
        digits += b - 48;
        push(kept, "d" + to_str(b));
    }
    last = i;
}
if last != len(long) - 1 {
    fail("index ended at " + to_str(last) + " of " + to_str(len(long)));
}
println("long " + to_str(len(long)) + " digits " + to_str(digits) + " kept " + to_str(len(kept)));

// lists and bytes with two names: index, then element
let names = ["ada", "bob"];
for i, n in names {
    println(to_str(i) + " " + n);
}
for i, b in b"\x01\x02" {
    println(to_str(i) + ":" + to_str(b));
}
