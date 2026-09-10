// bytes and list concatenation must sequence their operands.
//
// Two regressions in one:
//
//  1. `b"a" + b"b" + f()` used to abort the COMPILER with
//     "internal error: liveness-pending value has no registered temp".
//     When the right operand contains a call, liveness marks the left one
//     live across it and looks for the temp holding it; the bytes and
//     list concat paths never made one. Ordinary protocol-building code
//     could not be compiled.
//
//  2. Operands were embedded as sibling C arguments, whose relative
//     evaluation order C leaves unspecified -- while the liveness pass
//     assumes left to right.
//
// str concatenation always sequenced correctly; these two did not.

fn note(order: [int], tag: int) -> bytes {
    push(order, tag);
    return b"x";
}

fn note_list(order: [int], tag: int) -> [int] {
    push(order, tag);
    return [tag];
}

fn bump(n: int) -> bytes {
    let out = b"?";
    out[0] = n;
    return out;
}

fn ck(name: str, got: int, want: int) -> int {
    if got != want {
        println("FAIL " + name + ": got " + to_str(got) + " want " + to_str(want));
        return 1;
    }
    return 0;
}

let fails = 0;

// ---- the compiler no longer aborts -------------------------------
let a = b"a" + b"b" + bump(99);
fails = fails + ck("bytes-3way-len", len(a), 3);
fails = fails + ck("bytes-3way-b0", a[0], 97);
fails = fails + ck("bytes-3way-b2", a[2], 99);

let both = bump(65) + bump(66);
fails = fails + ck("call-plus-call", both[0], 65);
fails = fails + ck("call-plus-call-2", both[1], 66);

// a long alternating chain, the shape real frame building takes
let chain = b"a" + bump(1) + b"b" + bump(2) + b"c" + bump(3);
fails = fails + ck("chain-len", len(chain), 6);
fails = fails + ck("chain-1", chain[1], 1);
fails = fails + ck("chain-3", chain[3], 2);
fails = fails + ck("chain-5", chain[5], 3);

// ---- operands evaluate left to right -----------------------------
let order = [0];
let sink = note(order, 1) + note(order, 2) + note(order, 3);
fails = fails + ck("order-len", len(order), 4);   // seed + 3
fails = fails + ck("order-1", order[1], 1);
fails = fails + ck("order-2", order[2], 2);
fails = fails + ck("order-3", order[3], 3);
if len(sink) != 3 {
    println("FAIL sink length");
    fails = fails + 1;
}

// ---- same for lists ----------------------------------------------
let l = [1] + [2] + note_list(order, 7);
fails = fails + ck("list-3way-len", len(l), 3);
fails = fails + ck("list-3way-last", l[2], 7);

let lorder = [0];
let l2 = note_list(lorder, 11) + note_list(lorder, 12);
fails = fails + ck("list-order-len", len(l2), 2);
fails = fails + ck("list-order-first", l2[0], 11);
fails = fails + ck("list-order-second", l2[1], 12);

// ---- str concatenation was already correct; keep it that way -----
let s = "a" + "b" + to_str(len(order));
if len(s) != 3 {
    println("FAIL str-3way");
    fails = fails + 1;
}

if fails == 0 {
    println("all concat sequencing checks passed");
} else {
    println("FAILURES: " + to_str(fails));
    exit(1);
}
