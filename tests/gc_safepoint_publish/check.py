#!/usr/bin/env python3
"""Every safepoint record is complete before the task's chain points at it.

A call bracket fills a stack record (prev, roots, nroots) and then publishes
it with `t->safepoint_top = &record`. An async preemption can stop the task
between any two instructions, and the collector then walks the task's chain,
so a record published before its root count is stored is read with whatever
the stack held there: gcc did exactly that (pg's to_ready loop, SIGSEGV in
sl_gc_mark_task reading roots off the end of the stack).

This compiles the given programs, disassembles them (x86-64, GNU objdump,
AT&T syntax) and fails if a store of a record's address into the task's
safepoint_top (offset 0x20 of sl_task) is followed, before any call, jump or
return, by the store of that record's root count (record + 0x10).

usage: check.py SLANGC PROGRAM.sl...
"""
import os
import re
import subprocess
import sys
import tempfile

SAFEPOINT_TOP = 0x20  # offsetof(sl_task, safepoint_top)
NROOTS = 0x10         # offsetof(sl_safepoint, nroots)

LEA = re.compile(r"\tlea\s+(0x[0-9a-f]+)?\(%rsp\),(%\w+)$")
SPILL = re.compile(r"\tmov\s+(%\w+),(0x[0-9a-f]+)?\(%rsp\)$")
RELOAD = re.compile(r"\tmov\s+(0x[0-9a-f]+)?\(%rsp\),(%\w+)$")
PUBLISH = re.compile(r"\tmov\s+(%\w+),0x20\((%\w+)\)$")
COUNT = re.compile(r"\tmovl\s+\$0x[0-9a-f]+,(0x[0-9a-f]+)?\(%rsp\)$")
FLOW = re.compile(r"\t(call|jmp|ret|j[a-z]+)\b")


def off(s):
    return int(s, 16) if s else 0


def scan(binary):
    dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binary],
                         capture_output=True, text=True, check=True).stdout
    hits = []
    fn = None
    regs = {}     # register -> record offset it holds (from lea N(%rsp))
    slots = {}    # stack slot -> record offset spilled there
    pending = None
    for line in dis.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if m:
            fn, regs, slots, pending = m.group(1), {}, {}, None
            continue
        if "\t" not in line:
            continue
        ins = line.split(":", 1)[1].rstrip() if ":" in line else line
        if FLOW.search(ins):
            regs, pending = {}, None
            continue
        m = LEA.search(ins)
        if m:
            regs[m.group(2)] = off(m.group(1))
            continue
        m = SPILL.search(ins)
        if m and m.group(1) in regs:
            slots[off(m.group(2))] = regs[m.group(1)]
            continue
        m = RELOAD.search(ins)
        if m:
            o = off(m.group(1))
            if o in slots:
                regs[m.group(2)] = slots[o]
            else:
                regs.pop(m.group(2), None)
            continue
        m = PUBLISH.search(ins)
        if m and m.group(1) in regs:
            pending = (regs[m.group(1)], line.strip())
            continue
        m = COUNT.search(ins)
        if m and pending and off(m.group(1)) == pending[0] + NROOTS:
            hits.append("%s: %s ... %s" % (fn, pending[1], line.strip()))
            pending = None
            continue
        # any other write to a register forgets what it held
        m = re.search(r",(%\w+)$", ins)
        if m and not ins.lstrip().startswith(("cmp", "test")):
            regs.pop(m.group(1), None)
    return hits


def main():
    slangc = os.path.abspath(sys.argv[1])
    programs = [os.path.abspath(p) for p in sys.argv[2:]]
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for i, prog in enumerate(programs):
            out = os.path.join(tmp, "p%d" % i)
            r = subprocess.run([slangc, prog, "-o", out], capture_output=True,
                               text=True, cwd=tmp)
            if r.returncode != 0:
                print("FAIL safepoint publish order: cannot build %s" % prog)
                print(r.stderr[-2000:])
                return 1
            hits = scan(out)
            for h in hits:
                print("  %s: %s" % (prog, h))
            bad += len(hits)
    if bad:
        print("FAIL safepoint publish order: %d record(s) published before "
              "their root count" % bad)
        return 1
    print("PASS safepoint publish order (%d programs)" % len(programs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
