#!/usr/bin/env python3
"""Writes stdin.txt and expected.txt for tests/math_big: random integers
from a fixed seed, sized from 0 to 5000 bits so schoolbook, Karatsuba and
long division all run, with Python's own integers as the reference. Run
from this directory."""
import math, random

rnd = random.Random(20261121)

def num(bits):
    if bits == 0:
        return 0
    v = rnd.getrandbits(bits) | (1 << (bits - 1))
    return -v if rnd.random() < 0.4 else v

def pick():
    r = rnd.random()
    if r < 0.1:
        return rnd.choice([0, 1, -1, 2**32 - 1, 2**32, -(2**32), 2**63 - 1, -(2**63), 2**64])
    if r < 0.5:
        return num(rnd.randint(1, 130))
    if r < 0.85:
        return num(rnd.randint(130, 1400))
    return num(rnd.randint(1400, 5000))

def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q

def fmt(v, base):
    if v == 0:
        return "0"
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    s = []
    n = abs(v)
    while n:
        n, d = divmod(n, base)
        s.append(digits[d])
    return ("-" if v < 0 else "") + "".join(reversed(s))

inp, out = [], []
for case in range(300):
    a, b = pick(), pick()
    inp.append(f"{a} {b}")
    res = [a + b, a - b, a * b]
    if b != 0:
        q = tdiv(a, b)
        res += [q, a - q * b, a // b, a % abs(b)]
    else:
        res += ["none"] * 4
    res.append(math.gcd(a, b))
    s = rnd.randint(0, 200)
    res += [a << s, a >> s, a & b, a | b, a ^ b, ~a]
    res.append(math.isqrt(a) if a >= 0 else "none")
    base = rnd.choice([2, 8, 10, 16, 36])
    res.append(fmt(a, base))
    res.append(a if -(2**63) <= a < 2**63 else "none")
    res.append(a.bit_length())
    res.append(1 if a > b else (-1 if a < b else 0))
    out.append(" ".join(str(x) for x in res))
    inp[-1] += f" {s} {base}"
# modular arithmetic on positive moduli
for case in range(60):
    m = abs(pick()) + 2
    a = pick()
    e = abs(num(rnd.randint(1, 300)))
    inp.append(f"M {a} {e} {m}")
    inv = pow(a, -1, m) if math.gcd(a, m) == 1 else "none"
    out.append(f"{pow(a, e, m)} {inv}")
# odd moduli of two limbs and more: the Montgomery path
for case in range(40):
    m = abs(num(rnd.randint(33, 2100))) | 1
    a = pick()
    e = abs(num(rnd.randint(1, 2048)))
    inp.append(f"M {a} {e} {m}")
    inv = pow(a, -1, m) if math.gcd(a, m) == 1 else "none"
    out.append(f"{pow(a, e, m)} {inv}")
open("stdin.txt", "w").write("\n".join(inp) + "\n")
open("expected.txt", "w").write("\n".join(out) + "\n")
