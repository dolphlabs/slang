"""Generates tests/json_tape/{main.sl,expected.txt}.

encoding.json_tape against a reference tape built here by a separate
recursive-descent reader. The reference's accept/reject decision is
checked against Python's json module (with NaN/Infinity refused, which
RFC 8259 does not allow), and each string span it records must decode,
through json.loads, to the value Python read at that position -- so the
expected spans and counts are not just a second copy of the same code.

    python3 tests/json_tape/gen.py
"""
import json
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
WS = b" \t\n\r"


class Bad(Exception):
    pass


def tape_of(b):
    t = []

    def add(kind, frm, to):
        t.append([kind, len(t) + 1, 0, frm, to])
        return len(t) - 1

    def ws(i):
        while i < len(b) and b[i] in WS:
            i += 1
        return i

    def string(i):
        # b[i] == '"'; returns (close, escaped)
        j, esc = i + 1, False
        while j < len(b):
            c = b[j]
            if c == 0x22:
                return j, esc
            if c < 0x20:
                raise Bad()
            if c == 0x5C:
                esc = True
                j += 1
                if j >= len(b):
                    raise Bad()
                e = b[j]
                if e == 0x75:
                    h = b[j + 1:j + 5]
                    if len(h) < 4 or any(x not in b"0123456789abcdefABCDEF" for x in h):
                        raise Bad()
                    j += 4
                elif e not in b'"\\/bfnrt':
                    raise Bad()
            j += 1
        raise Bad()

    def number(i):
        j = i
        if j < len(b) and b[j] == 0x2D:
            j += 1
        if j >= len(b):
            raise Bad()
        if b[j] == 0x30:
            j += 1
        elif 0x31 <= b[j] <= 0x39:
            while j < len(b) and 0x30 <= b[j] <= 0x39:
                j += 1
        else:
            raise Bad()
        if j < len(b) and b[j] == 0x2E:
            j += 1
            if j >= len(b) or not 0x30 <= b[j] <= 0x39:
                raise Bad()
            while j < len(b) and 0x30 <= b[j] <= 0x39:
                j += 1
        if j < len(b) and b[j] in b"eE":
            j += 1
            if j < len(b) and b[j] in b"+-":
                j += 1
            if j >= len(b) or not 0x30 <= b[j] <= 0x39:
                raise Bad()
            while j < len(b) and 0x30 <= b[j] <= 0x39:
                j += 1
        return j

    def value(i, depth):
        i = ws(i)
        if i >= len(b):
            raise Bad()
        c = b[i]
        if c in b"[{":
            if depth >= 512:
                raise Bad()
            e = add(5 if c == 0x7B else 4, i, i)
            i = ws(i + 1)
            closer = 0x7D if c == 0x7B else 0x5D
            if i < len(b) and b[i] == closer:
                t[e][4] = i + 1
                return i + 1
            while True:
                t[e][2] += 1
                if c == 0x7B:
                    i = ws(i)
                    if i >= len(b) or b[i] != 0x22:
                        raise Bad()
                    close, esc = string(i)
                    add(15 if esc else 7, i + 1, close)
                    i = ws(close + 1)
                    if i >= len(b) or b[i] != 0x3A:
                        raise Bad()
                    i += 1
                i = ws(value(i, depth + 1))
                if i < len(b) and b[i] == 0x2C:
                    i += 1
                    continue
                if i < len(b) and b[i] == closer:
                    t[e][1] = len(t)
                    t[e][4] = i + 1
                    return i + 1
                raise Bad()
        if c == 0x22:
            close, esc = string(i)
            add(11 if esc else 3, i + 1, close)
            return close + 1
        for word, kind in ((b"true", 1), (b"false", 1), (b"null", 0)):
            if b[i:i + len(word)] == word:
                add(kind, i, i + len(word))
                return i + len(word)
        j = number(i)
        add(2, i, j)
        return j

    i = ws(value(0, 0))
    if i != len(b):
        raise Bad()
    return t


def strict_loads(s):
    def no_const(x):
        raise ValueError(x)
    return json.loads(s, parse_constant=no_const)


def check_spans(doc, t, b):
    """Every scalar span decodes to what Python read there."""
    flat = []

    def walk(v):
        if isinstance(v, dict):
            flat.append(("obj", len(v)))
            for k, x in v.items():
                flat.append(("key", k))
                walk(x)
        elif isinstance(v, list):
            flat.append(("list", len(v)))
            for x in v:
                walk(x)
        else:
            flat.append(("val", v))
    walk(doc)
    assert len(flat) == len(t), (flat, t)
    for (what, v), (kind, end, count, frm, to) in zip(flat, t):
        span = b[frm:to].decode("utf-8")
        if what in ("obj", "list"):
            assert count == v and kind == (5 if what == "obj" else 4)
            pass
        elif what == "key" or isinstance(v, str):
            assert json.loads('"' + span + '"') == v
            assert (kind & 8 != 0) == ("\\" in span)
        elif v is None:
            assert kind == 0
        elif isinstance(v, bool):
            assert kind == 1 and span == ("true" if v else "false")
        else:
            assert kind == 2 and strict_loads(span) == v


rnd = random.Random(20261110)


def rand_value(depth):
    r = rnd.random()
    if depth > 4 or r < 0.45:
        return rnd.choice([
            None, True, False, 0, -1, 12345678901, 3.5, -0.0, 1e-7, 2.5e300,
            "", "plain", "with \"quotes\" and \\ backslash", "tab\tnl\n",
            "\u00e9\u65e5\U0001f600", "\u2028", "</script>", "${x}", "\x01",
        ])
    if r < 0.7:
        return [rand_value(depth + 1) for _ in range(rnd.randint(0, 5))]
    return {rnd.choice(["a", "b", "name", "k\"q", "\u00e9", "", "x y", "n\n"]) + str(k): rand_value(depth + 1)
            for k in range(rnd.randint(0, 5))}


valid = [
    "0", "-0", "1.5e10", "true", "null", '""', '"x"', "[]", "{}", " [ 1 , 2 ] ",
    '{"a":[1,true,null],"b\\n":"x\\"y","c":{}}',
    '{"u":"\\u00e9\\ud83d\\ude00","s":"\\/"}',
    "\t\n[\r\n{}\t]\n",
    "[" * 512 + "]" * 512,
]
for _ in range(60):
    v = rand_value(0)
    if rnd.random() < 0.5:
        valid.append(json.dumps(v, ensure_ascii=False))
    else:
        valid.append(json.dumps(v, indent=rnd.choice([None, 1, "\t"]), ensure_ascii=rnd.random() < 0.5))

invalid = [
    "", " ", "[", "]", "[1,]", "[,1]", "{\"a\" 1}", "{\"a\":}", "{a:1}", "{\"a\":1,}", "01", "-", "1.", ".5",
    "1e", "1e+", "+1", "tru", "nul", "NaN", "Infinity", "\"\\q\"", "\"\\u12\"", "\"\\u12g4\"",
    "\"unterminated", "\"ctl\x01\"", "[1] 2", "{}{}", "[\"a\" \"b\"]", "[1 2]", "[" * 513 + "]" * 513,
    "{\"a\":1 \"b\":2}", "'single'",
]

src = ['// Generated by tests/json_tape/gen.py -- do not edit.',
       '// encoding.json_tape against a reference tape checked in gen.py',
       '// against Python\'s json module.',
       '',
       'import "encoding";',
       '',
       'fn show(s: str) {',
       '    let r = encoding.json_tape(s);',
       '    guard let t = r else { println("ERR"); return; }',
       '    let parts: [str] = [];',
       '    for k in 0..len(t) {',
       '        push(parts, to_str(t[k]));',
       '    }',
       '    println(strings.join(parts, " "));',
       '}',
       '']
src.insert(5, 'import "strings";')
exp = []


def lit(s):
    return 'to_str(b"' + "".join("\\x%02x" % c for c in s.encode("utf-8")) + '")'


for s in valid:
    b = s.encode("utf-8")
    doc = strict_loads(s)
    t = tape_of(b)
    check_spans(doc, t, b)
    src.append("show(%s);" % lit(s))
    exp.append(" ".join(str(x) for e in t for x in e))
for s in invalid:
    b = s.encode("utf-8")
    try:
        strict_loads(s)
        py_ok = True
    except (ValueError, RecursionError):
        py_ok = False
    try:
        tape_of(b)
        ours = True
    except (Bad, IndexError):
        ours = False
    # Python reads 513 levels; RFC 8259 lets a reader limit nesting, and
    # json_tape stops at 512
    if s.startswith("[" * 513):
        assert py_ok and not ours
    else:
        assert not py_ok and not ours, s
    src.append("show(%s);" % lit(s))
    exp.append("ERR")
# the error says what and where
src.append('println(err_of(encoding.json_tape("[1,}")));')
exp.append("json_tape: unexpected character at byte 3")

with open(os.path.join(HERE, "main.sl"), "w", encoding="utf-8") as f:
    f.write("\n".join(src) + "\n")
with open(os.path.join(HERE, "expected.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(exp) + "\n")
print("valid", len(valid), "invalid", len(invalid))
