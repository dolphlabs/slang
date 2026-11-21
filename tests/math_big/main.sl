// math/big against Python on fixed-seed vectors (gen.py): every
// operation on 300 pairs from 0 to 5000 bits, then modular power and
// inverse.
import "math/big";
import "io";
import "strings";

fn show(o: opt[big.Int]) -> str {
    if let v = o {
        return v.format(10);
    }
    return "none";
}

fn p(s: str) -> big.Int {
    return big.parse(s, 10) ?? big.zero();
}

while true {
    let lr = io.read_line();
    guard let lo = lr else { break; }
    guard let line = lo else { break; }
    let f = strings.split(line, " ");
    if f[0] == "M" {
        let a = p(f[1]);
        let e = p(f[2]);
        let m = p(f[3]);
        println(show(a.mod_pow(e, m)) + " " + show(a.mod_inv(m)));
        continue;
    }
    let a = p(f[0]);
    let b = p(f[1]);
    let s = to_int(f[2]) ?? 0;
    let base = to_int(f[3]) ?? 10;
    let r: [str] = [];
    push(r, a.add(b).format(10));
    push(r, a.sub(b).format(10));
    push(r, a.mul(b).format(10));
    push(r, show(a.div(b)));
    push(r, show(a.rem(b)));
    push(r, show(a.div_floor(b)));
    push(r, show(a.modulo(b)));
    push(r, a.gcd(b).format(10));
    push(r, a.shl(s).format(10));
    push(r, a.shr(s).format(10));
    push(r, a.and(b).format(10));
    push(r, a.or(b).format(10));
    push(r, a.xor(b).format(10));
    push(r, a.not().format(10));
    push(r, show(a.sqrt()));
    let text = a.format(base);
    push(r, text);
    // the round trip through that base
    let back = big.parse(text, base) ?? big.from_int(12345);
    assert(back.eq(a), "parse(format) round trip in base " + to_str(base));
    if let v = a.int_of() { push(r, to_str(v)); } else { push(r, "none"); }
    push(r, to_str(a.bit_len()));
    push(r, to_str(a.cmp(b)));
    println(strings.join(r, " "));
}
