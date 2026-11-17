"""Generates tests/toml_parity/{main.sl,expected.txt}.

Every document below goes through Python's tomllib, the reference: a
document it rejects must be an error from toml.to_json, and one it reads
must come out as the same values, written as toml.to_json writes JSON
(see render). The documents: the spec's examples and hand-written edge
cases, one invalid document per rule the spec states, seeded random
documents, and seeded one-character mutations of those (mostly invalid).

    python3 tests/toml_parity/gen.py

Needs a tomllib that reads TOML 1.0 (Python 3.11-3.13); later ones read
TOML 1.1, which accepts documents 1.0 rejects. The script checks.
"""
import datetime
import json
import os
import random
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
rnd = random.Random(10)


def is_toml_10():
    try:
        tomllib.loads("a = {b = 1,\n}")
    except tomllib.TOMLDecodeError:
        return True
    return False


if not is_toml_10():
    sys.exit("gen.py: this tomllib reads TOML 1.1; run it with Python 3.11-3.13")


# ---- the JSON toml.to_json writes ------------------------------------

def render(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            return "null"
        r = repr(v)
        return r[:-2] if r.endswith(".0") else r
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, datetime.datetime):
        s = v.isoformat()
        if v.tzinfo is not None and v.utcoffset() == datetime.timedelta(0):
            s = s[:-6] + "Z"
        return '"' + s + '"'
    if isinstance(v, (datetime.date, datetime.time)):
        return '"' + v.isoformat() + '"'
    if isinstance(v, list):
        return "[" + ",".join(render(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + render(x) for k, x in v.items()) + "}"
    raise TypeError(type(v))


def expect(doc):
    try:
        return "ok " + render(tomllib.loads(doc))
    except tomllib.TOMLDecodeError:
        return "err"


# ---- hand-written documents ------------------------------------------

VALID = [
    "",
    "# only a comment",
    "\n\n  \t\n",
    'title = "TOML Example"\n[owner]\nname = "Tom Preston-Werner"\ndob = 1979-05-27T07:32:00-08:00\n'
    '[database]\nenabled = true\nports = [ 8000, 8001, 8002 ]\ndata = [ ["delta", "phi"], [3.14] ]\n'
    'temp_targets = { cpu = 79.5, case = 72.0 }\n[servers]\n[servers.alpha]\nip = "10.0.0.1"\nrole = "frontend"\n'
    '[servers.beta]\nip = "10.0.0.2"\nrole = "backend"\n',
    'key = "value"\nbare_key = "value"\nbare-key = "value"\n1234 = "value"\n',
    '"127.0.0.1" = "value"\n"character encoding" = "value"\n"ʎǝʞ" = "value"\n\'key2\' = "value"\n\'quoted "value"\' = "value"\n',
    '"" = "blank"\n',
    "'' = 'blank'\n",
    'name = "Orange"\nphysical.color = "orange"\nphysical.shape = "round"\nsite."google.com" = true\n',
    'fruit.name = "banana"\nfruit. color = "yellow"\nfruit . flavor = "banana"\n',
    'apple.type = "fruit"\norange.type = "fruit"\napple.skin = "thin"\norange.skin = "thick"\n',
    '3.14159 = "pi"\n',
    'str = "I\'m a string. \\"You can quote me\\". Name\\tJos\\u00E9\\nLocation\\tSF."\n',
    'str1 = """\nRoses are red\nViolets are blue"""\n',
    'str2 = """\nThe quick brown \\\n\n\n  fox jumps over \\\n    the lazy dog."""\n',
    'str3 = """\\\n       The quick brown \\\n       fox jumps over \\\n       the lazy dog.\\\n       """\n',
    'str4 = """Here are two quotation marks: "". Simple enough."""\n',
    'str5 = """Here are three quotation marks: ""\\"."""\n',
    'str6 = """Here are fifteen quotation marks: ""\\"""\\"""\\"""\\"""\\"."""\n',
    'str7 = """"This," she said, "is just a pointless statement.""""\n',
    "winpath  = 'C:\\Users\\nodejs\\templates'\nwinpath2 = '\\\\ServerX\\admin$\\system32\\'\nquoted   = 'Tom \"Dubs\" Preston-Werner'\nregex    = '<\\i\\c*\\s*>'\n",
    "regex2 = '''I [dw]on't need \\d{2} apples'''\nlines  = '''\nThe first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved.\n'''\n",
    "quot15 = '''Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"'''\napos15 = \"Here are fifteen apostrophes: '''''''''''''''\"\nstr = ''''That,' she said, 'is still pointless.''''\n",
    "int1 = +99\nint2 = 42\nint3 = 0\nint4 = -17\nint5 = 1_000\nint6 = 5_349_221\nint7 = 53_49_221\nint8 = 1_2_3_4_5\n",
    "hex1 = 0xDEADBEEF\nhex2 = 0xdeadbeef\nhex3 = 0xdead_beef\noct1 = 0o01234567\noct2 = 0o755\nbin1 = 0b11010110\n",
    "a = 9223372036854775807\nb = -9223372036854775808\nc = 0x7FFFFFFFFFFFFFFF\nd = +0\ne = -0\n",
    "flt1 = +1.0\nflt2 = 3.1415\nflt3 = -0.01\nflt4 = 5e+22\nflt5 = 1e06\nflt6 = -2E-2\nflt7 = 6.626e-34\nflt8 = 224_617.445_991_228\n",
    "sf1 = inf\nsf2 = +inf\nsf3 = -inf\nsf4 = nan\nsf5 = +nan\nsf6 = -nan\nz = -0.0\nzz = +0.0\n",
    "bool1 = true\nbool2 = false\n",
    "odt1 = 1979-05-27T07:32:00Z\nodt2 = 1979-05-27T00:32:00-07:00\nodt3 = 1979-05-27T00:32:00.999999-07:00\nodt4 = 1979-05-27 07:32:00Z\n",
    "odt5 = 1979-05-27t07:32:00z\nldt1 = 1979-05-27T07:32:00\nldt2 = 1979-05-27T00:32:00.999999\nld1 = 1979-05-27\nlt1 = 07:32:00\nlt2 = 00:32:00.999999\n",
    "leap = 2024-02-29\ny2k = 2000-02-29T00:00:00Z\nedge = 1999-12-31T23:59:59+23:59\n",
    'integers = [ 1, 2, 3 ]\ncolors = [ "red", "yellow", "green" ]\nnested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]\n'
    'nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]\nstring_array = [ "all", \'strings\', """are the same""", \'\'\'type\'\'\' ]\n'
    'numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]\ncontributors = [\n  "Foo Bar <foo@example.com>",\n  { name = "Baz Qux", email = "bazqux@example.com", url = "https://example.com/bazqux" }\n]\n',
    "integers2 = [\n  1, 2, 3\n]\nintegers3 = [\n  1,\n  2, # this is ok\n]\nempty = []\nempty2 = [ # c\n]\n",
    '[table-1]\nkey1 = "some string"\nkey2 = 123\n[table-2]\nkey1 = "another string"\nkey2 = 456\n',
    '[dog."tater.man"]\ntype.name = "pug"\n',
    '[a.b.c]\n[ d.e.f ]\n[ g .  h  . i ]\n[ j . "ʞ" . \'l\' ]\n',
    "[x.y.z.w]\n[x]\n",
    '[fruit]\napple.color = "red"\napple.taste.sweet = true\n[fruit.apple.texture]\nsmooth = true\n',
    'name = { first = "Tom", last = "Preston-Werner" }\npoint = { x = 1, y = 2 }\nanimal = { type.name = "pug" }\nempty = {}\nnest = { a = { b = { c = [1, {d = 2}] } } }\n',
    '[[products]]\nname = "Hammer"\nsku = 738594937\n[[products]]  # empty table within the array\n[[products]]\nname = "Nail"\nsku = 284758393\ncolor = "gray"\n',
    '[[fruits]]\nname = "apple"\n[fruits.physical]\ncolor = "red"\nshape = "round"\n[[fruits.varieties]]\nname = "red delicious"\n'
    '[[fruits.varieties]]\nname = "granny smith"\n[[fruits]]\nname = "banana"\n[[fruits.varieties]]\nname = "plantain"\n',
    "points = [ { x = 1, y = 2, z = 3 },\n           { x = 7, y = 8, z = 9 },\n           { x = 2, y = 4, z = 8 } ]\n",
    "a = 1\r\nb = 'two'\r\n[t]\r\nc = \"\"\"x\r\ny\"\"\"\r\n",
    "a = 1 # comment with \t tab and é\n# full line\n  b = 2   \n",
    'unicode = "\\U0001F600 \\u00e9 \\u0000 \\u001f \\b\\f\\r"\nraw = "tab\there"\n',
    "k = \"\"\"\\\n   \\\n   x\"\"\"\n",
    'k = "a\\\\b\\"c"\n',
    "t = { a.b = 1, a.c = 2 }\n",
    '[a]\nb.c.d = 1\n[a.b.e]\nf = 2\n',
    '[[a]]\n[[a]]\nb = 1\n[a.c]\nd = 2\n',
    "big = 0b111111111111111111111111111111111111111111111111111111111111111\n",
    "f = 1e-07\ng = 123456789012345678.0\nh = 0.0001\ni = 1e20\nj = 1.5e300\n",
    "\"a\\tb\" = 1\n'c\\td' = 2\n",
]

INVALID = [
    "key = # no value",
    "first = \"Tom\" last = \"Preston-Werner\"",
    "= \"no key name\"",
    'name = "Tom"\nname = "Pradyun"',
    'spelling = "favorite"\n"spelling" = "favourite"',
    "fruit.apple = 1\nfruit.apple.smooth = true",
    'str = "a\nb"',
    "str = 'a\nb'",
    'str = "bad \\q escape"',
    'str = "\\uD800"',
    'str = "\\U00110000"',
    'str = "\\u12"',
    'str = """a""""""',
    "str = '''a''''''",
    'str = "unclosed',
    'str = """unclosed',
    "int = 0x_1",
    "int = 1__000",
    "int = _1",
    "int = 1_",
    "int = 01",
    "int = +0x1",
    "int = 0xG",
    "int = 0o8",
    "int = 0b2",
    "flt = .7",
    "flt = 7.",
    "flt = 3.e+20",
    "flt = 1e",
    "flt = 1._5",
    "flt = 1.5_",
    "flt = 01.5",
    "flt = infinity",
    "flt = Inf",
    "flt = NaN",
    "b = True",
    "b = truee",
    "d = 1979-13-27",
    "d = 1979-02-30",
    "d = 2023-02-29",
    "d = 1979-05-27T24:00:00",
    "d = 1979-05-27T07:60:00",
    "d = 1979-05-27T07:32:60",
    "d = 1979-05-27T07:32",
    "d = 1979-5-27",
    "d = 1979-05-27T07:32:00.",
    "d = 1979-05-27T07:32:00+25:00",
    "d = 1979-05-27T07:32:00+07",
    "t = 7:32:00",
    "t = 07:32",
    "a = [1, 2,, 3]",
    "a = [1 2]",
    "a = [,]",
    "a = [1",
    't = { a = 1, }',
    't = { a = 1\n}',
    't = {\n a = 1 }',
    't = { a = 1, a = 2 }',
    't = { a = 1 }\nt.b = 2',
    't = { a.b = 1 }\nt.a.c = 2',
    '[t]\na = 1\n[t]\nb = 2',
    '[fruit]\napple.color = "red"\n[fruit.apple]\ntexture = "smooth"',
    '[a.b]\nc = 1\n[a]\nb.d = 2',
    '[[fruits]]\nname = "apple"\n[fruits]\nx = 1',
    'fruits = []\n[[fruits]]\nx = 1',
    'a = [{ b = 1 }]\n[[a]]\nc = 2',
    'a = [{ b = 1 }]\n[a.c]\nd = 2',
    't = { a = 1 }\n[t.b]\nc = 2',
    "[a]\nx = 1\n[a.x]\ny = 2",
    "[a]]",
    "[[a]",
    "[a\nb]",
    "[]",
    "[a.]",
    "[.a]",
    "[a..b]",
    "[ [a]]",
    '["""a"""]',
    'a.""" b """ = 1',
    "a = 1\rb = 2",
    "a = 1 # bad \x01 control",
    "a = \"bad \x01 control\"",
    "a = 'bad \x7f control'",
    "a = 1\nb",
    "a.b.c",
    "a = 1 2",
    "a = {",
    "a = [[1, 2], [3, 4]",
    "@ = 1",
    "a b = 1",
    "a = 1979-05-27 07:32",
]

# tomllib reads these, as Python ints have no limit; the spec says an
# integer that cannot be held losslessly is an error, and slang's int is
# 64 bits.
OVER_64_BITS = [
    "int = 9223372036854775808",
    "int = -9223372036854775809",
    "int = 0x8000000000000000",
]


# ---- random documents ------------------------------------------------

BARE = "abcxyzABC019_-"
TEXT = ["a", "Z", " ", "é", "☃", "😀", "\\", '"', "'", "\t", "#", "=", "[", "]", ".", ","]


def rkey():
    r = rnd.random()
    if r < 0.6:
        return "".join(rnd.choice(BARE) for _ in range(rnd.randint(1, 4)))
    s = "".join(rnd.choice(["a", "b", " ", "é", ".", "=", "#", "😀"]) for _ in range(rnd.randint(0, 4)))
    if r < 0.8:
        return json.dumps(s, ensure_ascii=False)
    return "'" + s + "'"


def rbasic():
    out = []
    for _ in range(rnd.randint(0, 8)):
        c = rnd.choice(TEXT + ["\\n", "\\t", "\\u00e9", "\\U0001F600", "\\\\", '\\"', "\\b", "\\u0000", "\\u007f"])
        if c in ("\\", '"'):
            c = "\\" + c
        out.append(c)
    return '"' + "".join(out) + '"'


def rliteral():
    return "'" + "".join(rnd.choice([c for c in TEXT if c != "'"]) for _ in range(rnd.randint(0, 8))) + "'"


def rml_basic():
    parts = []
    for _ in range(rnd.randint(0, 6)):
        parts.append(rnd.choice(["a", "é", "\n", "\r\n", '"', '""', "\\n", "\\\n   ", "\t", "x y"]))
    s = "".join(parts)
    while s.endswith('"'):
        s = s[:-1]
    return '"""' + rnd.choice(["", "\n"]) + s + '"""'


def rml_literal():
    parts = []
    for _ in range(rnd.randint(0, 6)):
        parts.append(rnd.choice(["a", "é", "\n", "\r\n", "'", "''", "\\", "\t", "x y"]))
    s = "".join(parts)
    while s.endswith("'"):
        s = s[:-1]
    return "'''" + rnd.choice(["", "\n"]) + s + "'''"


def rint():
    r = rnd.random()
    if r < 0.5:
        n = rnd.randint(-10**12, 10**12)
        s = str(abs(n))
        if len(s) > 3 and rnd.random() < 0.4:
            s = s[0] + "_" + s[1:]
        sign = "-" if n < 0 else rnd.choice(["", "", "+"])
        return sign + s
    if r < 0.7:
        return "0x" + format(rnd.randint(0, 2**40), rnd.choice(["x", "X"]))
    if r < 0.85:
        return "0o" + format(rnd.randint(0, 2**30), "o")
    return "0b" + format(rnd.randint(0, 2**20), "b")


def rfloat():
    return rnd.choice(["1.5", "-0.25", "3.0", "1e3", "2.5E-3", "+6.02e23", "1_000.5", "0.1", "-1e-7",
                       "inf", "-inf", "nan", "123.456", "7e+2"])


def rdatetime(fractions):
    y, mo, d = rnd.randint(1, 9999), rnd.randint(1, 12), rnd.randint(1, 28)
    date = "%04d-%02d-%02d" % (y, mo, d)
    time = "%02d:%02d:%02d" % (rnd.randint(0, 23), rnd.randint(0, 59), rnd.randint(0, 59))
    if fractions and rnd.random() < 0.3:
        time += ".%06d" % rnd.randint(1, 999999)
    r = rnd.random()
    if r < 0.2:
        return date
    if r < 0.3:
        return time
    sep = rnd.choice(["T", "T", "t", " "])
    if r < 0.5:
        return date + sep + time
    off = rnd.choice(["Z", "z", "+05:30", "-08:00", "+00:01"])
    return date + sep + time + off


def rvalue(depth, fractions):
    r = rnd.random()
    if depth < 3 and r < 0.12:
        items = [rvalue(depth + 1, fractions) for _ in range(rnd.randint(0, 3))]
        if items and rnd.random() < 0.3:
            return "[\n  " + ",\n  ".join(items) + rnd.choice(["", ","]) + " # c\n]"
        return "[" + ", ".join(items) + "]"
    if depth < 3 and r < 0.22:
        pairs = [rkey() + " = " + rvalue(depth + 1, fractions) for _ in range(rnd.randint(0, 3))]
        return "{ " + ", ".join(pairs) + " }"
    if r < 0.40:
        return rbasic()
    if r < 0.48:
        return rliteral()
    if r < 0.53:
        return rml_basic()
    if r < 0.57:
        return rml_literal()
    if r < 0.72:
        return rint()
    if r < 0.82:
        return rfloat()
    if r < 0.87:
        return rnd.choice(["true", "false"])
    return rdatetime(fractions)


def rdoc(fractions):
    lines = []
    for _ in range(rnd.randint(1, 10)):
        r = rnd.random()
        if r < 0.12:
            lines.append("[" + ".".join(rkey() for _ in range(rnd.randint(1, 3))) + "]")
        elif r < 0.2:
            lines.append("[[" + ".".join(rkey() for _ in range(rnd.randint(1, 2))) + "]]")
        elif r < 0.25:
            lines.append(rnd.choice(["# a comment", "", "   "]))
        else:
            k = ".".join(rkey() for _ in range(rnd.choice([1, 1, 1, 2, 3])))
            lines.append(k + " = " + rvalue(0, fractions) + rnd.choice(["", "", " # note"]))
    nl = "\r\n" if rnd.random() < 0.15 else "\n"
    return nl.join(lines) + nl


def mutate(doc):
    if not doc:
        return doc
    i = rnd.randrange(len(doc))
    r = rnd.random()
    if r < 0.4:
        return doc[:i] + doc[i + 1:]
    if r < 0.8:
        return doc[:i] + rnd.choice(list('=[]{},."\'#\n .')) + doc[i:]
    j = rnd.randrange(len(doc))
    return doc[:i] + doc[j] + doc[i + 1:]


docs = list(VALID) + list(INVALID)
docs += [rdoc(True) for _ in range(250)]
docs += [mutate(rdoc(False)) for _ in range(350)]


# ---- output ----------------------------------------------------------

def lit(s):
    return 'to_str(b"' + "".join("\\x%02x" % c for c in s.encode("utf-8")) + '")'


src = ["// Generated by tests/toml_parity/gen.py -- do not edit.", "",
       'import "toml";', "",
       "fn show(r: result[str, str]) {",
       '    guard let j = r else { println("err"); return; }',
       '    println("ok " + j);',
       "}", "",
       "fn empty() -> str {",
       '    return "";',
       "}", ""]
want = []
for d in docs:
    if "\x00" in d:
        continue
    src.append("show(toml.to_json(" + (lit(d) if d else "empty()") + "));")
    want.append(expect(d))
for d in OVER_64_BITS:
    assert expect(d) != "err"
    src.append("show(toml.to_json(" + lit(d) + "));")
    want.append("err")

with open(os.path.join(HERE, "main.sl"), "w") as f:
    f.write("\n".join(src) + "\n")
with open(os.path.join(HERE, "expected.txt"), "w") as f:
    f.write("\n".join(want) + "\n")
print("%d documents: %d valid, %d errors" % (len(want), sum(w != "err" for w in want), sum(w == "err" for w in want)))
