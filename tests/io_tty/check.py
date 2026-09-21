#!/usr/bin/env python3
"""io behaviours a pipe cannot show: run real programs under a pty.

    python3 tests/io_tty/check.py [path/to/slangc]

1. prompt   print("name? ") is visible BEFORE anything is typed.
2. repl     Ctrl-D ends one read but is not sticky; Ctrl-C (with proc
            imported) is an "interrupted" error, not a kill.
3. tasks    two busy tasks finish while main waits on stdin, with one
            worker (SLANG_WORKERS=1).
4. term_size  io.term_width/height follow the window, and are none without
            a terminal.
5. secret    io.read_secret: no echo while it reads, echo back after.
6. raw_*     io.raw_on/read_key: keys arrive unechoed, and the terminal is
            put back by raw_off, by exit(), and when Ctrl-C ends the
            process -- with proc imported (an "interrupted" error) or
            without (a kill). A terminal left raw ruins the person's shell,
            so every way out is checked.

Waits are "until this text appears", with a generous timeout, never a
fixed sleep -- a loaded CI machine is slower, not wrong.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
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


def lflag(t):
    """The pty's local-mode flags as the child left them, or None."""
    try:
        return termios.tcgetattr(t.fd)[3]
    except termios.error:
        return None


def cooked(t):
    """Line editing and echo both on (what a shell expects)."""
    f = lflag(t)
    return f is not None and bool(f & termios.ICANON) and bool(f & termios.ECHO)


def raw(t):
    f = lflag(t)
    return f is not None and not (f & termios.ICANON) and not (f & termios.ECHO)


def wait_for(pred, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.02)
    return False


def set_size(t, rows, cols):
    fcntl.ioctl(t.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


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

        exe = build("term_size", tmp)
        if exe:
            t = Term(exe)
            # a fresh pty is 0x0, which is "no size", not a size of zero
            ok = t.expect("size -1x-1")
            set_size(t, 30, 100)
            t.send(b"\n")
            ok = ok and t.expect("size 100x30")
            set_size(t, 50, 120)
            t.send(b"\n")
            ok = ok and t.expect("size 120x50")
            t.send(b"\x04")
            code = t.finish()
            report("io_tty term_width/height follow the window",
                   ok and code == 0, "exit=%s output=%s" % (code, t.text()))
            p = subprocess.run([exe], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True)
            report("io_tty term_width/height are none without a terminal",
                   p.stdout == "size -1x-1\n" and p.returncode == 0,
                   "stdout=%r exit=%s" % (p.stdout, p.returncode))

        exe = build("secret", tmp)
        if exe:
            t = Term(exe)
            ok = t.expect("pw? ")
            off = wait_for(lambda: lflag(t) is not None and not (lflag(t) & termios.ECHO))
            t.send(b"hunter2\n")
            got = t.expect("got:hunter2")
            back = cooked(t)  # read_secret has returned: echo must be on again
            fin = t.expect("after")
            code = t.finish()
            typed_once = t.buf.count(b"hunter2") == 1  # the program's own line only
            newline = b"pw? \r\ngot:hunter2" in t.buf
            report("io_tty read_secret: no echo while reading, echo after",
                   ok and off and got and back and fin and typed_once and newline and code == 0,
                   "echo_off=%s echo_back=%s never_echoed=%s newline=%s exit=%s output=%s"
                   % (off, back, typed_once, newline, code, t.text()))

        exe = build("raw_keys", tmp)
        if exe:
            t = Term(exe)
            ok = t.expect("raw")
            in_raw = raw(t)
            t.send(b"Z")
            ok = ok and t.expect("key Z")
            t.send(b"\x1b[A")
            ok = ok and t.expect("key up")
            t.send(b"\x1b")  # nothing follows: the Escape key itself
            ok = ok and t.expect("key esc")
            t.send("\u00e9".encode())
            ok = ok and t.expect("key \u00e9")
            t.send(b"q")
            ok = ok and t.expect("done")
            back = cooked(t)
            code = t.finish()
            unechoed = t.buf.count(b"Z") == 1 and b"^[" not in t.buf
            report("io_tty raw mode: unechoed keys, terminal restored by raw_off",
                   ok and in_raw and back and unechoed and code == 0,
                   "raw=%s restored=%s unechoed=%s exit=%s output=%s"
                   % (in_raw, back, unechoed, code, t.text()))

        exe = build("raw_exit", tmp)
        if exe:
            t = Term(exe)
            ok = t.expect("ready")
            code = t.finish()
            back = cooked(t)
            report("io_tty raw mode is undone when the program exits",
                   ok and back and code == 0,
                   "restored=%s exit=%s output=%s" % (back, code, t.text()))

        exe = build("raw_die", tmp)
        if exe:
            t = Term(exe)
            ok = t.expect("raw")
            in_raw = raw(t)
            t.send(b"x")
            ok = ok and t.expect("key x")
            t.send(b"\x03")  # signals stay on in raw mode: this is SIGINT
            code = t.finish()
            back = cooked(t)
            report("io_tty Ctrl-C in raw mode kills the program and restores the terminal",
                   ok and in_raw and back and code == -signal.SIGINT,
                   "raw=%s restored=%s exit=%s output=%s" % (in_raw, back, code, t.text()))

        exe = build("raw_proc", tmp)
        if exe:
            t = Term(exe)
            ok = t.expect("raw")
            in_raw = raw(t)
            t.send(b"\x03")
            ok = ok and t.expect("ERR interrupted")
            code = t.finish()
            back = cooked(t)
            report("io_tty Ctrl-C in raw mode with proc is an error; terminal restored",
                   ok and in_raw and back and code == 3,
                   "raw=%s restored=%s exit=%s output=%s" % (in_raw, back, code, t.text()))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
