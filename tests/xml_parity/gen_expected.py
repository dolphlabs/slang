# Writes tests/xml_parity/expected.txt from cases.txt with Python's expat
# (namespaces on, DTDs refused): python3 gen_expected.py cases.txt > expected.txt
import sys, xml.parsers.expat
def q(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"'
# Refused here on purpose, though expat takes it: a non-UTF-8 encoding
# declaration.
POLICY = {46}
cases = open(sys.argv[1], encoding="utf-8").read().split("\n----\n")
out = []
for i, doc in enumerate(cases):
    if doc.endswith("\n----\n"): doc = doc[:-6]
    if doc.strip() == "": continue
    lines = []
    depth = [0]
    text = []
    def flush():
        if text:
            lines.append("  " * depth[0] + "T " + q("".join(text)))
            text.clear()
    class Refuse(Exception): pass
    def doctype(*a): raise Refuse("doctype")
    def start(name, attrs):
        flush()
        parts = name.split(" ")
        nm = "{%s}%s" % (parts[0], parts[1]) if len(parts) == 2 else name
        at = []
        for k in sorted(attrs):
            kp = k.split(" ")
            kn = "{%s}%s" % (kp[0], kp[1]) if len(kp) == 2 else k
            at.append("%s=%s" % (kn, q(attrs[k])))
        lines.append("  " * depth[0] + "E " + nm + (" " + " ".join(sorted(at)) if at else ""))
        depth[0] += 1
    def end(name):
        flush(); depth[0] -= 1
    def chars(d): text.append(d)
    p = xml.parsers.expat.ParserCreate(encoding=None, namespace_separator=" ")
    p.StartDoctypeDeclHandler = doctype
    p.StartElementHandler = start
    p.EndElementHandler = end
    p.CharacterDataHandler = chars
    p.ordered_attributes = False
    if i + 1 in POLICY:
        out.append("case %d: refused" % (i + 1)); continue
    try:
        p.Parse(doc.encode("utf-8"), True)
        flush()
        out.append("case %d: ok" % (i + 1))
        out.extend(lines)
    except Refuse:
        out.append("case %d: refused" % (i + 1))
    except xml.parsers.expat.ExpatError:
        out.append("case %d: refused" % (i + 1))
print("\n".join(out))
