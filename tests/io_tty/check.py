#!/usr/bin/env python3
"""io behaviours a pipe cannot show: run real programs under a pty.

    python3 tests/io_tty/check.py [path/to/slangc]

1. prompt   print("name? ") is visible BEFORE anything is typed.
2. repl     Ctrl-D ends one read but is not sticky; Ctrl-C (with proc
            imported) is an "interrupted" error, not a kill.
3. tasks    two busy tasks finish while main waits on stdin, with one
            worker (SLANG_WORKERS=1).

Waits are "until this text appears", with a generous timeout, never a
fixed sleep -- a loaded CI machine is slower, not wrong.
"""
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SLANGC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "slangc")
failed = False


def report(name, ok, detail=""):
    global failed
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + detail))
    if not ok:
        failed = True


def build(name, tmp):
    exe = os.path.join(tmp, name)
    r = subprocess.run([SLANGC, os.path.join(HERE, name, "main.sl"), "-o", exe],
                       capture_output=True, text=True)
    if r.returncode != 0:
        report("io_tty/" + name, False, "did not compile:\n" + r.stderr)
        return None
    return exe


class Term:
    """A child on a pty; expect() reads until text shows up."""

    def __init__(self, exe, env=None):
        self.buf = b""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if env:
                os.environ.update(env)
            os.execv(exe, [exe])

    def expect(self, text, timeout=15.0):
        end = time.time() + timeout
        while text.encode() not in self.buf and time.time() < end:
            if select.select([self.fd], [], [], 0.1)[0]:
                try:
                    d = os.read(self.fd, 4096)
                except OSError:
                    break
                if not d:
                    break
                self.buf += d
        return text.encode() in self.buf

    def send(self, data):
        os.write(self.fd, data)

    def finish(self, timeout=15.0):
        end = time.time() + timeout
        while time.time() < end:
            r, st = os.waitpid(self.pid, os.WNOHANG)
            if r:
                self.expect("\0", 0.2)  # drain
                return os.WEXITSTATUS(st) if os.WIFEXITED(st) else -os.WTERMSIG(st)
            self.expect("\0", 0.1)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return None

    def text(self):
        return self.buf.decode(errors="replace").replace("\r\n", " | ")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        exe = build("prompt", tmp)
        if exe:
            t = Term(exe)
            shown = t.expect("name? ")
            t.send(b"carol\n")
            got = t.expect("hello, carol")
            code = t.finish()
            report("io_tty prompt visible before input",
                   shown and got and code == 0,
                   "prompt_shown=%s reply=%s exit=%s output=%s" % (shown, got, code, t.text()))

        exe = build("repl", tmp)
        if exe:
            t = Term(exe)
            ok = t.expect("> ")
            t.send(b"hi\n")
            ok = ok and t.expect("got: hi")
            t.send(b"\x04")
            ok = ok and t.expect("<eof>")
            t.send(b"again\n")
            ok = ok and t.expect("got: again")
            t.send(b"\x04")
            ok = ok and t.expect("bye")
            code = t.finish()
            report("io_tty Ctrl-D is not sticky", ok and code == 0,
                   "exit=%s output=%s" % (code, t.text()))

            t = Term(exe)
            ok = t.expect("> ")
            t.send(b"\x03")
            ok = ok and t.expect("ERR: interrupted")
            code = t.finish()
            report("io_tty Ctrl-C is an error, not a kill", ok and code == 3,
                   "exit=%s output=%s" % (code, t.text()))

        exe = build("tasks", tmp)
        if exe:
            # On a pty so the tasks' output is line-buffered and visible
            # while main is still waiting; on a pipe it would sit in the
            # child's buffer until exit and prove nothing.
            t = Term(exe, env={"SLANG_WORKERS": "1"})
            ran = t.expect("task 1 done") and t.expect("task 2 done")
            still_waiting = t.buf.count(b"main got input") == 0
            t.send(b"go\n")
            got = t.expect("main got input")
            code = t.finish()
            report("io_tty other tasks run while main waits on stdin",
                   ran and still_waiting and got and code == 0,
                   "tasks_ran=%s main_still_waiting=%s reply=%s exit=%s output=%s"
                   % (ran, still_waiting, got, code, t.text()))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
