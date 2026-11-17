"""Generates tests/yaml_parity/{main.sl,expected.txt}.

Every document below goes through ruamel.yaml (0.18, safe loader, YAML
1.2), the reference: a stream it rejects must be an error from
yaml.to_json_all, and one it reads must come out as the same values,
written as yaml.to_json_all writes JSON (see render). The streams: config
files and edge cases written by hand, invalid ones for each rule, seeded
random streams in mixed styles, and seeded one-character mutations of
those (mostly invalid). A stream ruamel reads into something JSON has no
form for (a timestamp, two keys that differ only in type) is left out.

SPEC_OVER_RUAMEL lists where ruamel departs from YAML 1.2's core schema
or from slang's 64-bit integers; there the expected output is written out.

    python3 -m venv v && v/bin/pip install ruamel.yaml==0.18.6
    v/bin/python tests/yaml_parity/gen.py
"""
import datetime
import json
import os
import random
import re

import ruamel.yaml

HERE = os.path.dirname(os.path.abspath(__file__))
rnd = random.Random(12)


class Skip(Exception):
    pass


# ---- the JSON yaml.to_json_all writes --------------------------------

def key_name(k):
    if isinstance(k, bool):
        return "true" if k else "false"
    if k is None:
        return "null"
    if isinstance(k, (int, float)):
        return render(k)
    if isinstance(k, str):
        return k
    raise Skip("key of type %s" % type(k).__name__)


def render(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        if not -2**63 <= v < 2**63:
            raise Skip("big int")
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            return "null"
        r = repr(v)
        return r[:-2] if r.endswith(".0") else r
    if isinstance(v, str):
        if any(0xD800 <= ord(c) <= 0xDFFF for c in v):
            raise Skip("a lone surrogate")
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(render(x) for x in v) + "]"
    if isinstance(v, dict):
        names = [key_name(k) for k in v]
        if len(set(names)) != len(names):
            raise Skip("keys that differ only in type")
        return "{" + ",".join(json.dumps(n, ensure_ascii=False) + ":" + render(x) for n, x in zip(names, v.values())) + "}"
    raise Skip("value of type %s" % type(v).__name__)


def expect(doc):
    # PyYAML's scanner, which ruamel's is, departs from YAML 1.2 in flow
    # context: it reads "key:," as the key "key:", and refuses a plain
    # scalar that starts with ":" (":a"). Mutations make both.
    if re.search(r":[,\]}]", doc) or re.search(r"[{\[,]\s*:[^\s,\[\]{}]", doc):
        raise Skip("':' next to a flow indicator")
    # a loader that failed can fail the next load: one per stream
    y = ruamel.yaml.YAML(typ="safe", pure=True)
    try:
        docs = list(y.load_all(doc))
    except Exception as e:
        if "'\\t'" in str(e):
            # PyYAML's scanner, which ruamel's is, refuses tabs YAML 1.2
            # allows (in a plain scalar, after "key:")
            raise Skip("a tab ruamel refuses")
        return "err"
    try:
        out = [render(d) for d in docs]
    except RecursionError:
        raise Skip("a recursive structure")
    return "ok " + "\n   ".join(out)


# ---- hand-written streams --------------------------------------------

VALID = [
    "",
    "# only a comment\n",
    "---\n",
    "--- # a comment\n...\n",
    "\ufeffa: 1\n",
    "name: api\nport: 8080\ndebug: false\nratio: 0.75\ntimeout: ~\nhosts:\n  - db1.internal\n  - db2.internal\n",
    "server:\n  host: 0.0.0.0\n  port: 443\n  tls:\n    cert: /etc/tls/cert.pem\n    key: /etc/tls/key.pem\n",
    "services:\n- name: auth\n  replicas: 3\n- name: billing\n  replicas: 1\n  env:\n    MODE: live\n",
    "a: yes\nb: No\nc: on\nd: OFF\ne: y\nf: n\n",
    "t1: true\nt2: True\nt3: TRUE\nf1: false\nn1: null\nn2: Null\nn3: NULL\nn4: ~\nn5:\n",
    "i1: 0\ni2: -17\ni3: +42\ni4: 012\ni5: 0o17\ni6: 0x1F\ni7: 0xff\n",
    "f1: 1.5\nf2: -0.25\nf3: .5\nf4: 1.\nf5: 1e3\nf6: 6.02E+23\nf7: -1.5e-7\nf8: .inf\nf9: -.Inf\nf10: .NaN\n",
    "s1: 1.2.3\ns2: 0o8\ns3: 0xG\ns4: +\ns5: 1:30\ns6: .git\ns7: -dash\ns8: 12abc\ns9: e3\n",
    "url: http://example.com:8080/path?q=1\ntime: 12:30\nratio: 3:4\nemail: a@b.c\n",
    "a: b # a comment\nc: d#not a comment\ne: 'f' # c\ng: \"h\" # c\n",
    "key with spaces: value with spaces\n\"quoted key\": 1\n'single key': 2\n",
    "multi: this is\n  a plain scalar\n  over three lines\nnext: x\n",
    "para: first\n\n  second paragraph\n\n\n  third\n",
    "sq: 'it''s here'\nsq2: 'two\n  lines'\nsq3: 'blank\n\n  line'\n",
    'dq: "tab\\there\\nnew line \\"quoted\\" \\\\ back"\n'
    'dq2: "\\x41\\u00e9\\U0001F600 \\0 \\a \\b \\e \\v \\f \\r \\/ \\  \\N \\_ \\L \\P"\n',
    'dq3: "folded\n  over\n\n  lines"\ndq4: "escaped \\\n  break"\n',
    "lit: |\n  line one\n  line two\n\n  line four\nnext: 1\n",
    "fold: >\n  a\n  b\n\n  c\n    indented\n  d\nnext: 1\n",
    "strip: |-\n  x\n\nclip: |\n  y\n\n\nkeep: |+\n  z\n\n\nend: 1\n",
    "fs: >-\n  a\n  b\nfk: >+\n  a\n\n",
    "ind: |2\n    four spaces kept\n  two\n",
    "empty_lit: |\nnext: 1\n",
    "top: |\n\n  after an empty line\n",
    "- |\n  in a sequence\n- >\n  folded\n  here\n",
    "flow_seq: [a, b, [c, d], {e: f}]\nflow_map: {a: 1, b: [2, 3], 'c d': x}\n",
    "multi_line_flow: [\n  one,\n  two,  # comment\n  three,\n]\nfm: {\n  a: 1,\n  b: 2\n}\n",
    'json: {"a": 1, "b": [true, null, 1.5], "c": "x"}\n',
    "pairs: [a: 1, b: 2]\nnokey: {a, b: 2}\nempty: {}\nempty2: []\n",
    "colon: {url: http://x.y/z, k:v}\n",
    "base: &base\n  timeout: 30\n  retries: 3\nprod:\n  <<: *base\n  retries: 5\n",
    "a: &a {k: 1, p: a}\nb: &b {k: 2, q: b}\nm:\n  <<: [*a, *b]\n  own: 1\n",
    "x: &x hello\ny: *x\nz: [*x, *x]\n",
    "list: &l [1, 2]\ncopy: *l\nnested:\n  deep: *l\n",
    "- &a a\n- *a\n- &b {k: v}\n- *b\n",
    "&k key: value\nother: *k\n",
    "s: !!str 123\ni: !!int 42\nf: !!float 1\nb: !!bool true\nn: !!null ~\nm: !!map {a: 1}\nq: !!seq [1]\ne: !!str\n",
    "--- 1\n--- two\n--- [3]\n",
    "---\na: 1\n...\n---\nb: 2\n",
    "%YAML 1.2\n---\na: 1\n",
    "a: 1\r\nb:\r\n  - x\r\n  - y\r\nc: |\r\n  l1\r\n  l2\r\n",
    "- - a\n  - b\n- - - c\n",
    "k:\n- a\n- b\nk2: v\n",
    "- a: 1\n  b:\n    c: 2\n- x\n",
    "a:\n  - b:\n      c: d\n    e: f\n",
    "seq:\n    - four\n    - spaces\nmap:\n    k: v\n",
    "unicode: café ☃ 😀\n\"é\": 1\n",
    "-1: neg\n1.5: float\ntrue: bool\n",
    "a: \"\"\nb: ''\nc: \" \"\n",
    "nul: \"\\0\"\n",
    "long: a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f g h i j k l m n o p q r s t u v w x y z\n",
]

INVALID = [
    "a: 1\na: 2\n",
    "a:\n\tb: 1\n",
    "a:\n  b: 1\n c: 2\n",
    "a: b: c\n",
    "- a\nb: 1\n",
    "a: 1\n- b\n",
    "a: *nope\n",
    "a: &a [*a]\n",
    "a: !custom x\n",
    "[a, b]: c\n",
    "{a: 1}: c\n",
    "a: 'unterminated\n",
    'a: "unterminated\n',
    "a: [1, 2\n",
    "a: {b: 1\n",
    'a: "\\q"\n',
    "a: [1,,2]\n",
    "a: {b: 1, b: 2}\n",
    "a: |0\n  x\n",
    "a: @x\n",
    "a: `x\n",
    "a: %x\n",
    "a: , x\n",
    "- - a\n - b\n",
    "a: 1\n  b: 2\n",
    "key: value\n  more: x\n",
    "a: 'x' y\n",
    "a: [1] x\n",
    "<<: 1\n",
    "a:\n  <<: [1, 2]\n",
    "a: \x01\n",
    "--- a\nb: 1\n",
    "%YAML 2.0\n---\na: 1\n",
    "!!int: x\na: !!int abc\n",
    "a: !!float x\n",
]

# ruamel departs from YAML 1.2 or from 64-bit integers here.
SPEC_OVER_RUAMEL = [
    ("a: 1_000\n", 'ok {"a":"1_000"}'),
    ("a: 0b101\n", 'ok {"a":"0b101"}'),
    ("a: 2001-12-14t21:59:43.10-05:00\n", 'ok {"a":"2001-12-14t21:59:43.10-05:00"}'),
    ("a: 99999999999999999999\n", "err"),
    ("1: a\n'1': b\n", "err"),
    # a lone surrogate is not a character: ruamel keeps one in a str
    ('a: "\\uD800"\n', "err"),
    # under YAML 1.2, yes is a string, so not a valid !!bool
    ("a: !!bool yes\n", "err"),
    # YAML 1.2 allows a tab to separate a value from its key
    ("a:    spaced    \nb:\tx\n", 'ok {"a":"spaced","b":"x"}'),
    # not supported, by design: explicit keys and %TAG
    ("? complex\n: key\n", "err"),
    ("? \n", "err"),
    ("%TAG ! tag:example.com,2000:\n---\na: 1\n", "err"),
]


# ---- random streams --------------------------------------------------

WORDS = ["alpha", "beta", "gamma", "host", "port", "name", "x", "y z", "a-b", "a_b", "v1.2", "on", "no",
         "null", "true", "12", "0x1f", "1.5", "-3", "é", "☃ snow", "😀", "key:val", "a#b", "~"]
CHARS = ["a", "b", " ", "é", "😀", "'", '"', "\\", ":", "#", "-", "\t", "\n", ",", "[", "{", "&", "*", "!"]


def rstring():
    return "".join(rnd.choice(CHARS) for _ in range(rnd.randint(0, 7)))


def plain_ok(s):
    if not s or s != s.strip() or s[0] in "-?:,[]{}#&*!|>'\"%@`":
        return False
    if any(c in s for c in "\n\t#,[]{}") or ": " in s or s.endswith(":"):
        return False
    return True


def dq(s):
    out = []
    for c in s:
        if c == '"':
            out.append('\\"')
        elif c == "\\":
            out.append("\\\\")
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append(rnd.choice(["\\t", "\t"]))
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


def sq(s):
    if "\n" in s or "\t" in s:
        return dq(s)
    return "'" + s.replace("'", "''") + "'"


def scalar(s):
    r = rnd.random()
    if r < 0.5 and plain_ok(s):
        return s
    if r < 0.75:
        return sq(s)
    return dq(s)


def rkey():
    return scalar(rnd.choice(WORDS + ["k%d" % rnd.randint(0, 9)]))


def rleaf():
    r = rnd.random()
    if r < 0.4:
        return rnd.choice(WORDS)
    if r < 0.55:
        return str(rnd.randint(-1000, 1000))
    if r < 0.65:
        return rnd.choice(["1.5", "-0.25", ".5", "1e3", ".inf", ".nan", "3."])
    if r < 0.75:
        return rnd.choice(["true", "false", "null", "~", "yes", "No"])
    return rstring()


def leaf_text(v, ind):
    r = rnd.random()
    if isinstance(v, str) and "\n" not in v and r < 0.12 and v.strip() == v and v:
        return "|\n" + " " * (ind + 2) + v + "\n", True
    if isinstance(v, str) and r < 0.2 and v and "\n" not in v:
        return ">-\n" + " " * (ind + 2) + v + "\n", True
    return scalar(v) if isinstance(v, str) else v, False


def gen_value(depth):
    r = rnd.random()
    if depth < 4 and r < 0.25:
        return {"__map__": [(rkey(), gen_value(depth + 1)) for _ in range(rnd.randint(0, 4))]}
    if depth < 4 and r < 0.45:
        return [gen_value(depth + 1) for _ in range(rnd.randint(0, 4))]
    return rleaf()


def flow(v):
    if isinstance(v, dict):
        return "{" + ", ".join(k + ": " + flow(x) for k, x in v["__map__"]) + "}"
    if isinstance(v, list):
        return "[" + ", ".join(flow(x) for x in v) + "]"
    if plain_ok(v) and not any(c in v for c in ",[]{}:"):
        return v
    return dq(v)


anchors = []


def props(v):
    if rnd.random() < 0.08:
        name = "a%d" % len(anchors)
        anchors.append(name)
        return "&" + name + " "
    return ""


def block(v, ind, lines, prefix):
    """Writes v as the value after `prefix` (a line so far)."""
    pad = " " * ind
    if anchors and rnd.random() < 0.06:
        lines.append(prefix + " *" + rnd.choice(anchors))
        return
    if isinstance(v, dict):
        entries = v["__map__"]
        if not entries or rnd.random() < 0.15:
            lines.append(prefix + " " + flow(v))
            return
        lines.append(prefix + (" " + props(v)).rstrip())
        step = rnd.choice([2, 2, 4])
        for k, x in entries:
            block(x, ind + step, lines, " " * (ind + step) + k + ":")
            if rnd.random() < 0.1:
                lines.append(rnd.choice(["", "   # note", "#"]))
        return
    if isinstance(v, list):
        if not v or rnd.random() < 0.15:
            lines.append(prefix + " " + flow(v))
            return
        lines.append(prefix + (" " + props(v)).rstrip())
        step = rnd.choice([0, 2, 2]) if prefix.endswith(":") else 2
        for x in v:
            block(x, ind + step, lines, " " * (ind + step) + "-")
        return
    text, multi = leaf_text(v, ind)
    if multi:
        lines.append(prefix + " " + text.rstrip("\n"))
        return
    lines.append(prefix + " " + props(v) + text + rnd.choice(["", "", "  # c"]))


def rdoc():
    del anchors[:]
    lines = []
    docs = rnd.choice([1, 1, 1, 2])
    for d in range(docs):
        if docs > 1 or rnd.random() < 0.2:
            lines.append("---")
        top = {"__map__": [(rkey(), gen_value(1)) for _ in range(rnd.randint(1, 5))]}
        for k, x in top["__map__"]:
            block(x, 0, lines, k + ":")
    nl = "\r\n" if rnd.random() < 0.1 else "\n"
    return nl.join(lines) + nl


def mutate(doc):
    if not doc:
        return doc
    i = rnd.randrange(len(doc))
    r = rnd.random()
    if r < 0.4:
        return doc[:i] + doc[i + 1:]
    if r < 0.8:
        return doc[:i] + rnd.choice(list(":-#[]{},'\"&*!|> \n")) + doc[i:]
    j = rnd.randrange(len(doc))
    return doc[:i] + doc[j] + doc[i + 1:]


# ---- output ----------------------------------------------------------

def lit(s):
    return 'to_str(b"' + "".join("\\x%02x" % c for c in s.encode("utf-8")) + '")'


cases = []
for d in VALID + INVALID:
    cases.append((d, None))
for d, want in SPEC_OVER_RUAMEL:
    cases.append((d, want))
for _ in range(300):
    cases.append((rdoc(), None))
for _ in range(400):
    cases.append((mutate(rdoc()), None))

src = ["// Generated by tests/yaml_parity/gen.py -- do not edit.", "",
       'import "strings";',
       'import "yaml";', "",
       "fn show(r: result[[str], str]) {",
       '    guard let js = r else { println("err"); return; }',
       '    println("ok " + strings.join(js, "\\n   "));',
       "}", "",
       "fn empty() -> str {",
       '    return "";',
       "}", ""]
want = []
skipped = 0
for d, fixed in cases:
    if "\x00" in d:
        continue
    try:
        w = fixed if fixed is not None else expect(d)
    except Skip:
        skipped += 1
        continue
    src.append("show(yaml.to_json_all(" + (lit(d) if d else "empty()") + "));")
    want.append(w)

with open(os.path.join(HERE, "main.sl"), "w") as f:
    f.write("\n".join(src) + "\n")
with open(os.path.join(HERE, "expected.txt"), "w") as f:
    f.write("\n".join(want) + "\n")
print("%d streams: %d read, %d errors; %d left out" % (
    len(want), sum(w != "err" for w in want), sum(w == "err" for w in want), skipped))
