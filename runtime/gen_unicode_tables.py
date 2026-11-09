#!/usr/bin/env python3
"""Generate runtime/sl_unicode_tables.c from the Unicode Character Database.

    python3 runtime/gen_unicode_tables.py <ucd-dir> > runtime/sl_unicode_tables.c

<ucd-dir> holds UnicodeData.txt, CaseFolding.txt and
DerivedNormalizationProps.txt from https://www.unicode.org/Public/UCD/latest/ucd/
(the version is read from CaseFolding.txt's first line and written into the
output). Re-run it when moving to a new Unicode version, then run the
conformance test (tests/runtime/test_unicode), which needs that version's
NormalizationTest.txt and CaseFolding.txt in tests/runtime/unicode/.

What the tables hold, per code point:
  - canonical combining class (ccc)
  - NFC_Quick_Check (No or Maybe; Yes is the default)
  - the full canonical decomposition (recursively applied), excluding
    Hangul syllables, which the runtime decomposes arithmetically
  - the full case folding (CaseFolding.txt statuses C and F)
and, separately, the canonical composition pairs: every two-character
canonical decomposition whose composite is not Full_Composition_Exclusion.

Layout: a two-stage lookup. STAGE1[cp >> 7] names a 128-entry block,
STAGE2[block * 128 + (cp & 127)] names a record, RECS[record] holds the
properties. Identical blocks are stored once, which is what keeps 1.1M
code points in roughly a hundred kilobytes: most blocks are all-default.
Decompositions and foldings live in one uint32 array, DATA, as a length
followed by the code points; offset 0 is the empty entry.
"""

import re
import sys

# Reproduced in every generated file, as the licence requires; also in
# THIRD_PARTY.md. From https://www.unicode.org/license.txt.
UNICODE_LICENSE = """\
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
"""

SHIFT = 7
BLOCK = 1 << SHIFT
MAX_CP = 0x110000


def parse_ranges(field):
    if ".." in field:
        a, b = field.split("..")
        return int(a, 16), int(b, 16)
    v = int(field, 16)
    return v, v


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    ucd = sys.argv[1].rstrip("/")

    with open(ucd + "/CaseFolding.txt", encoding="utf-8") as f:
        first = f.readline()
    m = re.match(r"# CaseFolding-(\d+\.\d+\.\d+)\.txt", first)
    if not m:
        sys.exit("CaseFolding.txt has no version line")
    version = m.group(1)

    ccc = {}
    decomp = {}
    with open(ucd + "/UnicodeData.txt", encoding="utf-8") as f:
        for line in f:
            p = line.split(";")
            cp = int(p[0], 16)
            if int(p[3]):
                ccc[cp] = int(p[3])
            d = p[5]
            if d and not d.startswith("<"):
                decomp[cp] = [int(x, 16) for x in d.split()]

    def full(cp):
        if cp not in decomp:
            return [cp]
        out = []
        for c in decomp[cp]:
            out.extend(full(c))
        return out

    full_decomp = {cp: full(cp) for cp in decomp}

    nfc_qc = {}
    fce = set()
    with open(ucd + "/DerivedNormalizationProps.txt", encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            p = [x.strip() for x in line.split(";")]
            lo, hi = parse_ranges(p[0])
            if p[1] == "NFC_QC":
                for cp in range(lo, hi + 1):
                    nfc_qc[cp] = p[2]
            elif p[1] == "Full_Composition_Exclusion":
                fce.update(range(lo, hi + 1))

    fold = {}
    with open(ucd + "/CaseFolding.txt", encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            p = [x.strip() for x in line.split(";")]
            if p[1] in ("C", "F"):
                fold[int(p[0], 16)] = [int(x, 16) for x in p[2].split()]

    pairs = []
    for cp, d in decomp.items():
        if len(d) == 2 and cp not in fce:
            pairs.append((d[0], d[1], cp))
    pairs.sort()

    # Records and the shared DATA array.
    data = [0]
    seq_off = {(): 0}

    def seq(xs):
        t = tuple(xs)
        if t not in seq_off:
            seq_off[t] = len(data)
            data.append(len(t))
            data.extend(t)
        return seq_off[t]

    rec_index = {}
    recs = []

    def rec(r):
        if r not in rec_index:
            rec_index[r] = len(recs)
            recs.append(r)
        return rec_index[r]

    rec((0, 0, 0, 0))  # record 0: the default for every unlisted code point
    QC_NO, QC_MAYBE = 1, 2
    per_cp = [0] * MAX_CP
    for cp in set(ccc) | set(full_decomp) | set(nfc_qc) | set(fold):
        q = nfc_qc.get(cp)
        flags = QC_NO if q == "N" else QC_MAYBE if q == "M" else 0
        r = (ccc.get(cp, 0), flags,
             seq(full_decomp.get(cp, [])), seq(fold.get(cp, [])))
        per_cp[cp] = rec(r)

    if len(recs) > 0xFFFF or len(data) > 0xFFFF:
        sys.exit("tables outgrew 16-bit indices")

    blocks = {}
    stage1 = []
    stage2 = []
    for b in range(MAX_CP // BLOCK):
        blk = tuple(per_cp[b * BLOCK:(b + 1) * BLOCK])
        if blk not in blocks:
            blocks[blk] = len(blocks)
            stage2.extend(blk)
        stage1.append(blocks[blk])

    max_decomp = max(len(v) for v in full_decomp.values())
    max_fold = max(len(v) for v in fold.values())

    def emit_array(ctype, name, xs, per_line=12, fmt="{}"):
        print(f"static const {ctype} {name}[{len(xs)}] = {{")
        for i in range(0, len(xs), per_line):
            print("    " + ", ".join(fmt.format(x) for x in xs[i:i + per_line]) + ",")
        print("};")
        print()

    notice = "\n".join((" * " + l).rstrip() for l in UNICODE_LICENSE.splitlines())
    print(f"""/* GENERATED by runtime/gen_unicode_tables.py from the Unicode Character
 * Database, version {version}. Do not edit: re-run the generator.
 *
 * The tables are derived from Unicode data files, used under the
 * Unicode License v3, whose notice must travel with every copy:
 *
{notice}
 *
 * Two-stage lookup: SL_UC_STAGE1[cp >> {SHIFT}] is a block number,
 * SL_UC_STAGE2[block * {BLOCK} + (cp & {BLOCK - 1})] a record number, and
 * SL_UC_RECS[record] the properties. A decomposition or folding is an
 * offset into SL_UC_DATA: a length, then that many code points; offset 0
 * is the empty entry. {len(recs)} records, {len(blocks)} distinct blocks,
 * {len(pairs)} composition pairs. */

#define SL_UC_VERSION "{version}"
#define SL_UC_SHIFT {SHIFT}
#define SL_UC_QC_NO {QC_NO}
#define SL_UC_QC_MAYBE {QC_MAYBE}
/* The longest full canonical decomposition and case folding, in code
   points. */
#define SL_UC_MAX_DECOMP {max_decomp}
#define SL_UC_MAX_FOLD {max_fold}

typedef struct {{
    uint8_t ccc;
    uint8_t flags;
    uint16_t decomp;
    uint16_t fold;
}} sl_uc_rec;
""")
    print(f"static const sl_uc_rec SL_UC_RECS[{len(recs)}] = {{")
    for r in recs:
        print("    {%d, %d, %d, %d}," % r)
    print("};")
    print()
    emit_array("uint16_t", "SL_UC_STAGE1", stage1, 16)
    emit_array("uint16_t", "SL_UC_STAGE2", stage2, 16)
    emit_array("uint32_t", "SL_UC_DATA", data, 10, "0x{:X}")
    print("/* Composition pairs sorted by (first, second): composite. */")
    print(f"#define SL_UC_NPAIRS {len(pairs)}")
    print(f"static const uint32_t SL_UC_PAIRS[{len(pairs)}][3] = {{")
    for a, b, c in pairs:
        print("    {0x%X, 0x%X, 0x%X}," % (a, b, c))
    print("};")


if __name__ == "__main__":
    main()
