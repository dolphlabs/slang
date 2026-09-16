#!/usr/bin/env python3
"""Build the slang documentation site.

Design rules, in order of importance:

1. ONE SOURCE OF TRUTH. Nothing here restates what the repository
   already says. Guide prose comes from README.md sections, the native
   package API comes from the NatSig tables in src/codegen/pkg_*/sigs.c,
   and source package APIs come from the `pub` declarations in
   stdlib/**/*.sl. A site that duplicates its own repo drifts from it
   within a month, and stale docs are worse than none.

2. AGENTS ARE FIRST-CLASS READERS. Every page ships a Markdown twin at
   the same path, linked from the HTML head. /llms.txt indexes the site
   for a model, /llms-full.txt is the whole thing as one plain-text
   document, and /api.json is the machine-readable API index. Content is
   in the HTML itself -- JavaScript only adds theme, search and motion,
   so a fetch with no JS engine still gets everything.

3. NO DEPENDENCIES. Python 3 standard library only. Someone cloning this
   repo can build the docs without a package manager, a lockfile, or a
   network connection.

Usage:  python3 www/build.py [--out docs]
"""

import argparse
import html
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Who builds this. Stated once here and threaded through the HTML, the
# Markdown twins, llms.txt and api.json -- an agent reading the plain
# text should learn it as readily as someone looking at the footer.
ORG = "Dolphlabs"
ORG_ENTITY = "Dolph Tech Limited"
ORG_URL = "https://dolphlabs.com"
WWW = ROOT / "www"

# --------------------------------------------------------------------
# Site map: which README sections become which page.
#
# Keyed by output path. `sections` names README headings verbatim; the
# builder pulls each heading and everything under it, up to the next
# heading of the same or higher level. Order here is the order on the
# page and in the navigation.
# --------------------------------------------------------------------

PAGES = [
    {
        "path": "index.html",
        "title": "slang",
        "tagline": "A statically typed language built primarily for "
                   "server-side and network programming. Compiles to C.",
        "kind": "home",
        "nav": "Home",
        "sections": ["Quick start"],
    },
    {
        "path": "guide/index.html",
        "title": "Language guide",
        "tagline": "Values, types, and the shape of a slang program.",
        "kind": "doc",
        "nav": "Guide",
        "sections": ["Language tour", "Built-ins", "Types",
                     "Numeric conversion rules",
                     "Bitwise operations and integer literals"],
    },
    {
        "path": "guide/data.html",
        "title": "Data types",
        "tagline": "bytes, lists, maps and structs.",
        "kind": "doc",
        "nav": "Data types",
        "sections": ["bytes", "Lists `[T]`", "Maps `map[K]V`", "Structs"],
    },
    {
        "path": "guide/errors.html",
        "title": "Errors",
        "tagline": "opt, result and fault -- and the rule for choosing.",
        "kind": "doc",
        "nav": "Errors",
        "sections": ["Option / Result",
                     "Error model: `opt` vs `result` vs `fault`"],
    },
    {
        "path": "guide/functions.html",
        "title": "Function values",
        "tagline": "Functions as values, deliberately without closures.",
        "kind": "doc",
        "nav": "Functions",
        "sections": ["Function values"],
    },
    {
        "path": "concurrency/index.html",
        "title": "Concurrency",
        "tagline": "M:N green threads, channels, select and mutex.",
        "kind": "doc",
        "nav": "Concurrency",
        "sections": ["Concurrency"],
    },
    {
        "path": "packages/index.html",
        "title": "Packages",
        "tagline": "The standard library, and how imports resolve.",
        "kind": "packages",
        "nav": "Packages",
        "sections": ["Standard packages"],
    },
    {
        "path": "interop/index.html",
        "title": "C interop",
        "tagline": "Calling C, and the safety rules that come with it.",
        "kind": "doc",
        "nav": "C interop",
        "sections": ["C interop", "Packages (Go/Odin style)"],
    },
    {
        "path": "internals/index.html",
        "title": "How it works",
        "tagline": "The compiler pipeline, the collector, the scheduler.",
        "kind": "doc",
        "nav": "Internals",
        "sections": ["How it works", "Memory management", "Project layout"],
    },
    {
        "path": "limitations/index.html",
        "title": "Limitations",
        "tagline": "What slang does not do, stated plainly.",
        "kind": "doc",
        "nav": "Limitations",
        "sections": ["Known limitations"],
    },
]

# Package pages are generated from extracted API data; this table adds
# the one thing source cannot carry -- which README section describes it.
PACKAGE_SECTIONS = {
    "time": ["`time`"],
    "net": ["`net`", "TLS"],      # TLS lives in net as net.tls_*
    "json": ["`json`"],
    "proc": ["`proc`"],
    "fs": ["`fs`"],
    "os": ["`os`"],
    "log": ["`log`"],
    "crypto": ["`crypto`"],
    "sql": ["`sql`"],
    "regex": ["`regex`"],
    "http2": ["`http2`"],
    "strings": ["`strings`"],
    "byteutil": ["`byteutil`"],
    "http": ["`http`"],
}

# --------------------------------------------------------------------
# Extraction: the API index
# --------------------------------------------------------------------

# NatArgKind -> the slang type a caller actually writes.
ARGKIND = {
    "NA_INT": "int",
    "NA_I64": "int",
    "NA_F64": "float",
    "NA_STR": "str",
    "NA_BYTES": "bytes",
    "NA_RAWPTR": "rawptr",
    "NA_UNTIL": "until",
    "NA_STR_FAULT": "str",
    "0": "",
}


def native_package_names():
    """The list the compiler itself uses. Read from loader.c so that a
    package added there cannot silently go undocumented -- a package with
    no NatSig table (json, whose calls are type-directed rather than
    fixed-arity) still gets a page from its README section."""
    text = (ROOT / "src" / "loader.c").read_text(encoding="utf-8")
    m = re.search(r"NATIVE_PKGS\[\]\s*=\s*\{(.*?)\};", text, re.S)
    if not m:
        return []
    return [n.lower() for n in re.findall(r"PKG_([A-Z0-9_]+)_NAME", m.group(1))]


def extract_native_packages():
    """Parse the NatSig tables that define every compiler-provided
    package. These are the authoritative list: if a function is callable
    from slang, it has a row here."""
    pkgs = {}
    for sigs in sorted((ROOT / "src" / "codegen").glob("pkg_*/sigs.c")):
        text = sigs.read_text(encoding="utf-8")
        # {"pkg", "name", nargs, {KINDS}, "ret", is_tls}
        row = re.compile(
            r'\{\s*"([a-z0-9_]+)"\s*,\s*"([a-z0-9_]+)"\s*,\s*(\d+)\s*,'
            r'\s*\{([^}]*)\}\s*,\s*(NULL|"[^"]*")\s*,\s*(\d+)\s*\}')
        for m in row.finditer(text):
            pkg, name, nargs, kinds, ret, is_tls = m.groups()
            kinds = [k.strip() for k in kinds.split(",") if k.strip()]
            params = [ARGKIND.get(k, k) for k in kinds][:int(nargs)]
            ret = None if ret == "NULL" else ret.strip('"')
            pkgs.setdefault(pkg, {"name": pkg, "kind": "native",
                                  "items": []})
            pkgs[pkg]["items"].append({
                "name": name,
                "params": params,
                "ret": ret,
                "tls": bool(int(is_tls)),
                "sig": "%s.%s(%s)%s" % (
                    pkg, name, ", ".join(params),
                    " -> " + ret if ret else ""),
            })
    return pkgs


DECL = re.compile(
    r"^pub\s+(fn|struct|gc\s+struct|let)\s+([A-Za-z_][A-Za-z0-9_]*)")


def extract_source_packages():
    """Parse `pub` declarations out of stdlib source, with the comment
    block immediately above each one as its documentation. This is the
    convention every slang package is expected to follow -- write a
    comment above a `pub` item and it becomes that item's docs."""
    pkgs = {}
    stdlib = ROOT / "stdlib"
    if not stdlib.is_dir():
        return pkgs
    for sl in sorted(stdlib.rglob("*.sl")):
        pkg = sl.relative_to(stdlib).parts[0]
        lines = sl.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            m = DECL.match(line)
            if not m:
                continue
            kind, name = m.group(1), m.group(2)
            # walk back over a contiguous run of // comments
            doc = []
            j = i - 1
            while j >= 0 and lines[j].lstrip().startswith("//"):
                doc.append(lines[j].lstrip()[2:].strip())
                j -= 1
            doc.reverse()
            # a banner of dashes is a section divider, not documentation
            while doc and set(doc[0]) <= set("- "):
                doc.pop(0)
            sig = line.rstrip().rstrip("{").strip()
            sig = re.sub(r"^pub\s+", "", sig)
            pkgs.setdefault(pkg, {"name": pkg, "kind": "source",
                                  "items": []})
            pkgs[pkg]["items"].append({
                "name": name,
                "decl": kind.replace("gc struct", "struct"),
                "sig": sig,
                "doc": " ".join(doc).strip(),
                "file": str(sl.relative_to(ROOT)),
                "line": i + 1,
            })
    return pkgs


# --------------------------------------------------------------------
# README sectioning
# --------------------------------------------------------------------

def read_sections(md_path):
    """Split a markdown file into {heading_text: (level, body_lines)}.

    A section owns everything until the next heading at the same or a
    higher level, so pulling "Types" brings its `####` subsections with
    it while pulling one `####` does not swallow its siblings."""
    lines = md_path.read_text(encoding="utf-8").splitlines()
    heads = []
    for i, line in enumerate(lines):
        m = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if m:
            heads.append((i, len(m.group(1)), m.group(2)))
    out = {}
    for idx, (i, level, text) in enumerate(heads):
        end = len(lines)
        for j, lv, _ in heads[idx + 1:]:
            if lv <= level:
                end = j
                break
        out[text] = (level, lines[i + 1:end])
    return out


# --------------------------------------------------------------------
# Markdown -> HTML (the subset this repository actually writes)
# --------------------------------------------------------------------

SLANG_KEYWORDS = {
    "let", "fn", "if", "else", "while", "return", "true", "false", "pub",
    "import", "guard", "for", "in", "as", "struct", "gc", "own", "mut",
    "impl", "extern", "link", "spawn", "break", "continue", "unsafe",
    "select", "case", "default",
}
SLANG_TYPES = {
    "int", "float", "str", "bool", "bytes", "i8", "i16", "i32", "i64",
    "u8", "u16", "u32", "u64", "f32", "map", "opt", "result", "duration",
    "rawptr", "arena", "chan", "join", "wire", "until", "fault", "peer",
    "trip", "mutex", "void", "ptr",
}
SLANG_BUILTINS = {
    "println", "print", "len", "push", "pop", "to_str", "to_bytes",
    "some", "none", "ok", "err", "err_of", "exit", "make_chan",
    "chan_send", "chan_recv", "chan_close", "make_mutex", "mutex_lock",
    "mutex_unlock", "mutex_trylock", "join_wait", "spawn", "nullptr",
    "arena_new", "until_of", "until_never", "until_hit", "bytes_ptr",
    "to_le", "to_be", "from_le", "from_be", "has", "del",
}

TOKEN = re.compile(r"""
    (?P<comment>//[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*")
  | (?P<number>\b\d[\w.]*\b)
  | (?P<word>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>[{}()\[\];,.:=+\-*/%<>!&|^~?])
""", re.VERBOSE)


def highlight(code, lang):
    """Build-time syntax highlighting. Done here rather than in the
    browser so that the markup is in the HTML a crawler or an agent
    reads, and so the page needs no JavaScript to be legible."""
    if lang not in ("slang", "sl", ""):
        return html.escape(code)
    out, pos = [], 0
    for m in TOKEN.finditer(code):
        out.append(html.escape(code[pos:m.start()]))
        pos = m.end()
        text = html.escape(m.group(0))
        kind = m.lastgroup
        cls = None
        if kind == "comment":
            cls = "c"
        elif kind == "string":
            cls = "s"
        elif kind == "number":
            cls = "n"
        elif kind == "word":
            w = m.group(0)
            if w in SLANG_KEYWORDS:
                cls = "k"
            elif w in SLANG_TYPES:
                cls = "t"
            elif w in SLANG_BUILTINS:
                cls = "b"
            elif code[m.end():m.end() + 1] == "(":
                cls = "f"
        out.append('<span class="%s">%s</span>' % (cls, text) if cls
                   else text)
    out.append(html.escape(code[pos:]))
    return "".join(out)


def inline(text):
    """Inline markdown. Code spans are extracted first and restored last
    so that nothing inside them is treated as markup."""
    spans = []

    def stash(m):
        spans.append(m.group(1))
        return "\x00%d\x00" % (len(spans) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                  lambda m: '<a href="%s">%s</a>' % (m.group(2), m.group(1)),
                  text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"\x00(\d+)\x00",
                  lambda m: "<code>%s</code>"
                            % html.escape(spans[int(m.group(1))]), text)
    return text


def md_to_html(lines, heading_shift=0):
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]

        if line.startswith("```"):
            lang = line[3:].strip()
            body, i = [], i + 1
            while i < n and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            code = "\n".join(body)
            out.append(
                '<div class="code"><button class="copy" type="button" '
                'aria-label="Copy code">Copy</button><pre><code>%s</code>'
                '</pre></div>' % highlight(code, lang))
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            lv = min(6, len(m.group(1)) + heading_shift)
            text = m.group(2)
            slug = re.sub(r"[^a-z0-9]+", "-",
                          re.sub(r"`", "", text).lower()).strip("-")
            out.append('<h%d id="%s">%s<a class="anchor" href="#%s" '
                       'aria-label="Link to this section">#</a></h%d>'
                       % (lv, slug, inline(text), slug, lv))
            i += 1
            continue

        if line.startswith("|") and i + 1 < n and re.match(
                r"^\|[\s:|-]+\|$", lines[i + 1]):
            head = [c.strip() for c in line.strip("|").split("|")]
            i += 2
            rows = []
            while i < n and lines[i].startswith("|"):
                rows.append([c.strip()
                             for c in lines[i].strip("|").split("|")])
                i += 1
            out.append('<div class="tablewrap"><table><thead><tr>'
                       + "".join("<th>%s</th>" % inline(c) for c in head)
                       + "</tr></thead><tbody>"
                       + "".join("<tr>%s</tr>" % "".join(
                           "<td>%s</td>" % inline(c) for c in r)
                           for r in rows)
                       + "</tbody></table></div>")
            continue

        if re.match(r"^\s*[-*]\s+", line) or re.match(r"^\s*\d+\.\s+", line):
            ordered = bool(re.match(r"^\s*\d+\.\s+", line))
            items, base = [], len(line) - len(line.lstrip())
            while i < n:
                cur = lines[i]
                m2 = re.match(r"^(\s*)(?:[-*]|\d+\.)\s+(.*)$", cur)
                if m2 and len(m2.group(1)) <= base:
                    items.append([m2.group(2)])
                    i += 1
                elif items and (cur.strip() == "" or
                                len(cur) - len(cur.lstrip()) > base):
                    if cur.strip() == "":
                        if i + 1 < n and re.match(r"^\s*(?:[-*]|\d+\.)\s+",
                                                  lines[i + 1]):
                            i += 1
                            continue
                        break
                    items[-1].append(cur.strip())
                    i += 1
                else:
                    break
            tag = "ol" if ordered else "ul"
            out.append("<%s>%s</%s>" % (
                tag,
                "".join("<li>%s</li>" % inline(" ".join(it))
                        for it in items),
                tag))
            continue

        if line.startswith(">"):
            body = []
            while i < n and lines[i].startswith(">"):
                body.append(lines[i].lstrip(">").strip())
                i += 1
            out.append("<blockquote>%s</blockquote>"
                       % md_to_html(body, heading_shift))
            continue

        if line.strip() == "":
            i += 1
            continue

        para = []
        while i < n and lines[i].strip() and not lines[i].startswith(
                ("```", "#", "|", ">")) and not re.match(
                r"^\s*(?:[-*]|\d+\.)\s+", lines[i]):
            para.append(lines[i].strip())
            i += 1
        if para:
            out.append("<p>%s</p>" % inline(" ".join(para)))
    return "\n".join(out)


# --------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------

def rel(depth):
    return "../" * depth if depth else "./"


def nav_html(pages, current, depth):
    out = []
    for p in pages:
        cls = ' class="active"' if p["path"] == current else ""
        out.append('<a%s href="%s%s">%s</a>'
                   % (cls, rel(depth), p["path"], html.escape(p["nav"])))
    return "".join(out)


def page_html(tpl, *, title, tagline, body, depth, nav, mdpath,
              extra_head="", hero=""):
    return (tpl
            .replace("{{TITLE}}", html.escape(title))
            .replace("{{TAGLINE}}", html.escape(tagline))
            .replace("{{BODY}}", body)
            .replace("{{NAV}}", nav)
            .replace("{{ROOT}}", rel(depth))
            .replace("{{MD}}", mdpath)
            .replace("{{HERO}}", hero)
            .replace("{{EXTRA_HEAD}}", extra_head))


def md_twin(title, tagline, sections_md):
    head = "# %s\n\n> %s\n\n" % (title, tagline)
    body = "\n\n".join(p.strip() for p in sections_md if p.strip())
    foot = ("\n\n---\n\nslang is built and maintained by **%s** "
            "(%s) — %s\n" % (ORG, ORG_ENTITY, ORG_URL))
    return head + body + foot


def build(out_dir):
    out = Path(out_dir)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    tpl = (WWW / "theme" / "base.html").read_text(encoding="utf-8")
    readme = read_sections(ROOT / "README.md")

    native = extract_native_packages()
    for name in native_package_names():
        native.setdefault(name, {"name": name, "kind": "native",
                                 "items": []})
    source = extract_source_packages()
    all_pkgs = dict(sorted({**native, **source}.items()))

    pages = list(PAGES)
    for name in all_pkgs:
        pages.append({
            "path": "packages/%s.html" % name,
            "title": name,
            "tagline": "Package %s." % name,
            "kind": "package",
            "nav": name,
            "sections": [],
            "_pkg": name,
        })

    navpages = [p for p in PAGES]
    search = []
    llms_parts = []
    single_pages = []

    for p in pages:
        depth = p["path"].count("/")
        body_parts, md_parts = [], []

        if p["kind"] == "home":
            body_parts.append(home_body())
            md_parts.append(home_md())

        if p["kind"] == "package":
            pkg = all_pkgs[p["_pkg"]]
            for sec in PACKAGE_SECTIONS.get(pkg["name"], []):
                prose = readme.get(sec)
                if not prose:
                    print("  ! missing README section: %r" % sec,
                          file=sys.stderr)
                    continue
                body_parts.append(md_to_html(prose[1], heading_shift=1))
                md_parts.append("\n".join(prose[1]).strip())
            body_parts.append(api_html(pkg))
            md_parts.append(api_md(pkg))
        else:
            for name in p["sections"]:
                sec = readme.get(name)
                if not sec:
                    print("  ! missing README section: %r" % name,
                          file=sys.stderr)
                    continue
                lvl, lines = sec
                shift = 1 - lvl + 1
                body_parts.append(
                    "<h2 id=\"%s\">%s</h2>" % (
                        re.sub(r"[^a-z0-9]+", "-",
                               name.replace("`", "").lower()).strip("-"),
                        inline(name)))
                body_parts.append(md_to_html(lines, heading_shift=shift))
                md_parts.append("## %s\n\n%s" % (name.replace("`", ""),
                                                 "\n".join(lines).strip()))

        if p["kind"] == "packages":
            body_parts.append(package_index_html(all_pkgs, depth))
            md_parts.append(package_index_md(all_pkgs))

        mdrel = re.sub(r"\.html$", ".md", p["path"])
        body = "\n".join(body_parts)
        target = out / p["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page_html(
            tpl, title=p["title"], tagline=p["tagline"], body=body,
            depth=depth, nav=nav_html(navpages, p["path"], depth),
            mdpath=rel(depth) + mdrel,
            hero=HERO if p["kind"] == "home" else "",
        ), encoding="utf-8")

        twin = md_twin(p["title"], p["tagline"], md_parts)
        (out / mdrel).write_text(twin, encoding="utf-8")

        single_pages.append({"path": p["path"], "title": p["title"],
                             "tagline": p["tagline"], "body": body,
                             "nav": p.get("nav"), "kind": p["kind"]})
        search.append({"title": p["title"], "url": p["path"],
                       "tagline": p["tagline"],
                       "text": re.sub(r"\s+", " ",
                                      re.sub(r"<[^>]+>", " ", body))[:4000]})
        llms_parts.append("# %s\n\n%s\n" % (p["title"], twin))

    # ---- agent surfaces ----
    (out / "search.json").write_text(json.dumps(search), encoding="utf-8")
    (out / "api.json").write_text(
        json.dumps({
            "project": "slang",
            "maintainer": {"name": ORG, "entity": ORG_ENTITY,
                           "url": ORG_URL},
            "packages": all_pkgs,
        }, indent=2), encoding="utf-8")

    llms = ["# slang",
            "",
            "> A statically typed language built primarily for "
            "server-side and network programming -- that is the focus, "
            "not a limit. Compiles to C. M:N green threads, a precise "
            "mark-sweep collector, and native packages. Built and "
            "maintained by %s (%s), %s." % (ORG, ORG_ENTITY, ORG_URL),
            "",
            "Every page on this site has a Markdown twin at the same path "
            "with a .md extension. /api.json is the machine-readable index "
            "of every package and function. /llms-full.txt is this entire "
            "site as one plain-text document.",
            "",
            "## Pages", ""]
    for p in pages:
        llms.append("- [%s](%s): %s" % (
            p["title"], re.sub(r"\.html$", ".md", p["path"]), p["tagline"]))
    (out / "llms.txt").write_text("\n".join(llms) + "\n", encoding="utf-8")
    (out / "llms-full.txt").write_text("\n\n".join(llms_parts),
                                       encoding="utf-8")

    for asset in ("style.css", "app.js"):
        shutil.copy(WWW / "theme" / asset, out / asset)
    (out / ".nojekyll").write_text("", encoding="utf-8")

    # Cloudflare Pages reads _headers; GitHub Pages ignores the file, so
    # shipping it costs nothing and fixes two things on Cloudflare.
    #
    # text/plain rather than text/markdown for the .md twins: both are
    # defensible, but text/markdown makes some browsers DOWNLOAD the file
    # instead of showing it, and these pages are meant to be readable by
    # a person who clicked "Markdown version" as much as by a program.
    #
    # The CORS header is what lets a tool running on another origin fetch
    # api.json or llms.txt at all. Without it the agent-facing half of
    # this site is only reachable by things that ignore the browser's
    # same-origin rules.
    (out / "_headers").write_text("""/*.md
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *

/*.txt
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *

/*.json
  Content-Type: application/json; charset=utf-8
  Access-Control-Allow-Origin: *

/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
""", encoding="utf-8")
    (out / "robots.txt").write_text(
        "User-agent: *\nAllow: /\n", encoding="utf-8")

    write_single_file(out, tpl, single_pages)

    n_items = sum(len(p["items"]) for p in all_pkgs.values())
    print("built %d pages, %d packages, %d API items -> %s"
          % (len(pages), len(all_pkgs), n_items, out))


def write_single_file(out, tpl, pages):
    """One self-contained HTML file holding the entire site: every page
    inlined, CSS and JS inlined, links rewritten to in-page navigation.

    This is not a gimmick -- it is the copy you can read on a plane, mail
    to someone, or hand to a tool that would rather fetch one URL than
    crawl twenty. It is also the honest way to preview the design without
    deploying anything."""
    css = (WWW / "theme" / "style.css").read_text(encoding="utf-8")
    js = (WWW / "theme" / "app.js").read_text(encoding="utf-8")

    nav = "".join(
        '<a href="#%s" data-go="%s">%s</a>'
        % (slug_of(p["path"]), slug_of(p["path"]), html.escape(p["nav"]))
        for p in pages if p.get("nav") and p["kind"] != "package")

    views = []
    for p in pages:
        body = re.sub(r'href="((?:\.\./)*)([a-z0-9/]+)\.html"',
                      lambda m: 'href="#%s"' % slug_of(m.group(1) + ".html"),
                      p["body"])
        views.append(
            '<section class="view" id="%s" hidden>'
            '<header class="page-head"><h1>%s</h1>'
            '<p class="tagline">%s</p></header>%s</section>'
            % (slug_of(p["path"]), html.escape(p["title"]),
               html.escape(p["tagline"]), body))

    doc = (tpl
           .replace("<title>{{TITLE}} — slang</title>",
                    "<title>slang Documentation</title>")
           .replace('<link rel="stylesheet" href="{{ROOT}}style.css">',
                    "<style>%s</style>" % css)
           .replace('<script src="{{ROOT}}app.js" defer></script>',
                    "<script>%s</script><script>%s</script>"
                    % (js, ROUTER_JS))
           .replace("{{TITLE}}", "slang documentation")
           .replace("{{TAGLINE}}",
                    "The whole site, in one file. Built and maintained "
                    "by %s (%s)." % (ORG, ORG_ENTITY))
           .replace("{{NAV}}", nav)
           .replace('href="{{ROOT}}index.html"', 'href="#home"')
           .replace("{{ROOT}}", "")
           .replace("{{MD}}", "llms-full.txt")
           .replace("{{EXTRA_HEAD}}", "")
           .replace("{{HERO}}", HERO)
           .replace("{{BODY}}", "".join(views)))
    # the per-page header is inside each view; drop the outer one
    doc = re.sub(r'<header class="page-head">\s*<h1>\{?\{?TITLE.*?</header>',
                 "", doc, flags=re.S)
    (out / "offline.html").write_text(doc, encoding="utf-8")


def slug_of(path):
    return re.sub(r"[^a-z0-9]+", "-",
                  re.sub(r"(index)?\.html$", "", path)).strip("-") or "home"


ROUTER_JS = """
(function () {
  var views = [].slice.call(document.querySelectorAll('.view'));
  var links = [].slice.call(document.querySelectorAll('[data-go]'));
  var hero = document.querySelector('.hero');
  function show(id) {
    var found = false;
    views.forEach(function (v) {
      var on = v.id === id;
      v.hidden = !on;
      if (on) found = true;
    });
    if (!found && views.length) { views[0].hidden = false; id = views[0].id; }
    if (hero) hero.hidden = (id !== 'home');
    links.forEach(function (a) {
      a.classList.toggle('active', a.getAttribute('data-go') === id);
    });
    document.querySelectorAll('#toc').forEach(function (t) { t.innerHTML = ''; });
    window.scrollTo(0, 0);
  }
  function current() { return (location.hash || '#home').slice(1); }
  window.addEventListener('hashchange', function () { show(current()); });
  show(current());
})();
"""


# --------------------------------------------------------------------
# Page fragments
# --------------------------------------------------------------------

HERO = """
<div class="hero">
  <div class="hero-copy">
    <p class="eyebrow">A <a href="https://dolphlabs.com"
       rel="noopener">Dolphlabs</a> project</p>
    <h1>slang</h1>
    <p class="lede">A statically typed language built <strong>primarily
      for server-side and network programming</strong> &mdash; that is
      where it is aimed, not where it stops. It compiles to C, schedules
      <strong>M:N green threads</strong>, collects with a precise
      mark-sweep GC, and ships its standard library inside the
      compiler.</p>
    <div class="cta">
      <a class="btn primary" href="./guide/">Read the guide</a>
      <a class="btn" href="./packages/">Browse packages</a>
      <a class="btn ghost" href="./llms.txt">llms.txt</a>
    </div>
  </div>
  <div class="hero-demo">
    <div class="demo-head">
      <span class="dot r"></span><span class="dot y"></span>
      <span class="dot g"></span>
      <span class="demo-title">six 300ms requests, one connection</span>
    </div>
    <div class="lanes" id="lanes"></div>
    <div class="demo-foot">
      <button class="btn small" id="run-demo" type="button">Run</button>
      <span class="readout" id="readout">idle</span>
    </div>
  </div>
</div>
"""


def home_body():
    return """
<section class="features">
  <article>
    <h3>Concurrency that is actually concurrent</h3>
    <p><code>spawn</code> submits a green task onto striped, work-stealing
      run queues. Channels, <code>select</code> and <code>mutex</code> park
      the <em>task</em>, never the OS thread, so a blocked handler costs a
      queue slot rather than one of the pool's threads.</p>
  </article>
  <article>
    <h3>Errors you cannot quietly drop</h3>
    <p><code>opt[T]</code> for absent data, <code>result[T, E]</code> for
      bad data, <code>fault</code> for a bad world. <code>guard let x = r
      else let e = err_of(r)</code> binds the error so it can be logged
      rather than thrown away.</p>
  </article>
  <article>
    <h3>C is the runtime, not a foreign country</h3>
    <p>slang emits C and shells out to <code>cc</code>. Calling a C library
      is <code>extern fn</code> plus a linker flag &mdash; no bindings
      generator, no FFI marshalling layer, no second build system.</p>
  </article>
  <article>
    <h3>Built for agents to read</h3>
    <p>Every page here has a Markdown twin at the same URL, the whole site
      is one file at <code>/llms-full.txt</code>, and every package and
      function is indexed in <code>/api.json</code>.</p>
  </article>
</section>
"""


def home_md():
    return (
        "slang is a statically typed language built primarily for "
        "server-side and network programming -- that is the focus, not a "
        "limit. It compiles to C, schedules M:N green threads, "
        "collects with a precise mark-sweep GC, and ships its standard "
        "library inside the compiler.\n")


def api_html(pkg):
    rows = []
    for it in pkg["items"]:
        if pkg["kind"] == "native":
            sig = it["sig"]
            doc = ""
            meta = ' <span class="tag">OpenSSL</span>' if it["tls"] else ""
        else:
            sig = it["sig"]
            doc = it.get("doc", "")
            meta = (' <span class="src">%s:%d</span>'
                    % (html.escape(it["file"]), it["line"]))
        anchor = re.sub(r"[^a-z0-9]+", "-", it["name"].lower()).strip("-")
        rows.append(
            '<div class="api-item" id="%s">'
            '<div class="api-sig"><code>%s</code>%s'
            '<a class="anchor" href="#%s">#</a></div>%s</div>'
            % (anchor, highlight(sig, "slang"), meta, anchor,
               '<p class="api-doc">%s</p>' % inline(doc) if doc else ""))
    if not rows:
        return ""
    return ('<h2 id="api">API<a class="anchor" href="#api">#</a></h2>'
            '<div class="api">%s</div>' % "".join(rows))


def api_md(pkg):
    if not pkg["items"]:
        return ""
    out = ["## API", ""]
    for it in pkg["items"]:
        out.append("### `%s`" % it["sig"])
        if it.get("doc"):
            out.append("")
            out.append(it["doc"])
        out.append("")
    return "\n".join(out)


def package_index_html(pkgs, depth):
    cards = []
    for name, pkg in pkgs.items():
        kind = ("compiler-provided" if pkg["kind"] == "native"
                else "source package")
        cards.append(
            '<a class="pkg-card" href="%s%s.html">'
            '<h3>%s</h3><p class="pkg-kind">%s</p>'
            '<p class="pkg-count">%d public items</p></a>'
            % (rel(depth) + "packages/", name, html.escape(name), kind,
               len(pkg["items"])))
    return ('<h2 id="all-packages">All packages'
            '<a class="anchor" href="#all-packages">#</a></h2>'
            '<div class="pkg-grid">%s</div>' % "".join(cards))


def package_index_md(pkgs):
    out = ["## All packages", ""]
    for name, pkg in pkgs.items():
        out.append("- [%s](packages/%s.md) -- %s, %d public items"
                   % (name, name,
                      "compiler-provided" if pkg["kind"] == "native"
                      else "source package", len(pkg["items"])))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs"))
    args = ap.parse_args()
    build(args.out)


if __name__ == "__main__":
    main()
