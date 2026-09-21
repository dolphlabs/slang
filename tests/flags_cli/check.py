#!/usr/bin/env python3
"""flags.parse_or_exit against a real command line.

Usage: check.py ./slangc

parse_or_exit's contract is its stdout, its stderr and its exit status --
none of which a slang program can observe about itself -- so this builds
one small program and runs it with a range of arguments.
"""
import os
import subprocess
import sys
import tempfile

slangc = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp()
binary = os.path.join(tmp, "cli")

build = subprocess.run([slangc, os.path.join(here, "prog", "main.sl"), "-o", binary],
                       capture_output=True, text=True)
if build.returncode != 0:
    print("FAIL flags_cli (build): " + build.stderr.strip())
    sys.exit(1)

USAGE = """Usage: cli [options] [words...]

a test program

Options:
  -n, --name <str>   who to greet (default: "world")
  -c, --count <int>  how many times (default: 1)
  -l, --loud         shout
  -h, --help         show this help
"""

cases = [
    ("no arguments", [], "hello world\n", "", 0),
    ("flags and positionals",
     ["--name", "bob", "-c", "2", "x", "-l", "y"],
     "hello bob!\nhello bob!\narg x\narg y\n", "", 0),
    ("-- ends the flags", ["--", "--name"], "hello world\narg --name\n", "", 0),
    ("--help", ["--help"], USAGE, "", 0),
    ("-h wins over a valid rest", ["-c", "3", "-h"], USAGE, "", 0),
    ("unknown flag", ["--bogus"], "",
     "cli: unknown flag --bogus\nTry 'cli --help' for usage.\n", 2),
    ("missing value", ["--name"], "",
     "cli: --name needs a value\nTry 'cli --help' for usage.\n", 2),
    ("bad integer", ["-c", "abc"], "",
     "cli: --count: invalid value \"abc\" (not a base-10 integer)\n"
     "Try 'cli --help' for usage.\n", 2),
]

failed = 0
for label, args, want_out, want_err, want_rc in cases:
    r = subprocess.run([binary] + args, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    problems = []
    if r.stdout != want_out:
        problems.append("stdout %r, want %r" % (r.stdout, want_out))
    if r.stderr != want_err:
        problems.append("stderr %r, want %r" % (r.stderr, want_err))
    if r.returncode != want_rc:
        problems.append("exit %d, want %d" % (r.returncode, want_rc))
    if problems:
        failed += 1
        print("FAIL flags_cli " + label + ": " + "; ".join(problems))
    else:
        print("PASS flags_cli " + label)

sys.exit(1 if failed else 0)
