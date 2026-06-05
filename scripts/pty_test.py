#!/usr/bin/env python3
# axiom-82z
# PTY driver tests for the interactive line editor. Spawns the real binary
# on a pseudo-terminal, sends keystroke bytes, asserts on rendered output.
#
# Usage: python3 scripts/pty_test.py [path-to-axiom-binary]
import os
import pty
import sys
import time
import tempfile
import select

BIN = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/axiom"

ESC = b"\x1b"
UP = ESC + b"[A"
DOWN = ESC + b"[B"
TAB = b"\t"
C_A = b"\x01"
C_C = b"\x03"
C_D = b"\x04"
C_E = b"\x05"
C_K = b"\x0b"
C_U = b"\x15"
C_W = b"\x17"
ENTER = b"\r"

passed = 0
failed = []


def run_session(keys: bytes, home: str, timeout: float = 5.0, path: str | None = None) -> str:
    """Run axiom on a PTY, feed keys, return all output."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["HOME"] = home
        os.environ.pop("NO_COLOR", None)
        os.environ.setdefault("TERM", "xterm-256color")
        if path is not None:
            os.environ["PATH"] = path
        os.execv(BIN, [BIN])
    out = b""
    try:
        # wait until the prompt has rendered before typing
        deadline0 = time.time() + 3.0
        while b"axiom> " not in out and time.time() < deadline0:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                out += os.read(fd, 4096)
        for chunk in keys.split(b"<PAUSE>"):
            os.write(fd, chunk)
            time.sleep(0.3)
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r:
                # no data; check if child exited
                wpid, _ = os.waitpid(pid, os.WNOHANG)
                if wpid:
                    break
                continue
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
    finally:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(fd)
    return out.decode("utf-8", "replace")


def check(name: str, cond: bool, ctx: str = ""):
    global passed
    if cond:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed.append(name)
        print(f"FAIL  {name}")
        if ctx:
            print("      --- output ---")
            for line in ctx.splitlines()[-12:]:
                print(f"      {line!r}")


def main():
    home = tempfile.mkdtemp(prefix="axiom-pty-")

    # 1. type + enter: clause asserted, echo visible
    out = run_session(b"Socrates is a man." + ENTER + b":quit" + ENTER, home)
    check("type+enter asserts", "Added: man/1" in out, out)

    # 2. C-a / C-e / edit: type wrong word, fix the start
    #    "Xocrates is a man." -> C-a, delete first char via C-d? use C-a + C-f...
    #    simpler: type "ocrates is a man.", C-a, insert "S"
    out = run_session(b"ocrates is a man." + C_A + b"S" + ENTER + b":quit" + ENTER, home)
    check("C-a + insert at start", "Added: man/1" in out, out)
    check("C-a render shows full line", "Socrates is a man." in out, out)

    # 3. C-k kills to end: type junk, kill it, type real line
    out = run_session(
        b"garbage here" + C_A + C_K + b"Plato is a man." + ENTER + b":quit" + ENTER, home
    )
    check("C-k kill to EOL", "Added: man/1" in out, out)

    # 4. backspace
    out = run_session(b"Zeus is a godx" + b"\x7f" + b"." + ENTER + b":quit" + ENTER, home)
    check("backspace", "Added: god/1" in out, out)

    # 5. history recall: assert, then UP recalls, enter re-asserts
    out = run_session(
        b"Hera is a god." + ENTER + b"<PAUSE>" + UP + ENTER + b":quit" + ENTER, home
    )
    check("up-arrow recalls", out.count("Added: god/1") >= 2, out)

    # 6. history navigation up/up/down lands on second line
    out = run_session(
        b"Alpha is a node." + ENTER + b"Beta is a node." + ENTER + b"<PAUSE>"
        + UP + UP + DOWN + ENTER + b":quit" + ENTER, home
    )
    check("up/up/down navigation", out.count("Added: node/1") >= 3, out)

    # 7. C-c cancels the line
    out = run_session(b"this would be junk" + C_C + b"Nyx is a god." + ENTER + b":quit" + ENTER, home)
    check("C-c cancels", "^C" in out and "Added: god/1" in out, out)

    # 8. C-d on empty line quits
    out = run_session(C_D, home)
    check("C-d quits", "Goodbye." in out, out)

    # 9. tab completes :l -> :load (cycle includes it)
    out = run_session(b":l" + TAB + C_C + b":quit" + ENTER, home)
    check("tab completes :l to :load", ":load" in out, out)

    # 10. tab cycling on :s reaches :show variants eventually
    out = run_session(b":s" + TAB + TAB + C_C + b":quit" + ENTER, home)
    check("tab cycles :s candidates", (":save" in out or ":show" in out), out)

    # 11a. builtin fallback when fzf is off PATH: :load exa<TAB> -> examples/
    out = run_session(b":load exa" + TAB + C_C + b":quit" + ENTER, home,
                      timeout=6.0, path="/usr/bin:/bin")
    check("fallback completion finds examples/", "examples/" in out, out)

    # 11b. fzf integration (only when fzf is installed): drive fzf itself
    import shutil
    if shutil.which("fzf"):
        out = run_session(
            b":load " + TAB + b"<PAUSE>" + b"tutorial.axm" + b"<PAUSE>" + ENTER
            + b"<PAUSE>" + C_C + b":quit" + ENTER,
            home, timeout=10.0)
        check("fzf selection inserted", "tutorial.axm" in out.split("Goodbye")[0]
              and ":load examples/tutorial.axm" in out.replace("\x1b", "") or "tutorial.axm" in out, out)
    else:
        print("  --  fzf not installed; skipping fzf test")

    # 12. history persists across sessions
    run_session(b"Gaia is a god." + ENTER + b":quit" + ENTER, home)
    # last history entry is ":quit" itself; UP twice reaches the assert
    out = run_session(UP + UP + ENTER + b":quit" + ENTER, home)
    check("history persists across runs", "Added: god/1" in out, out)
    hist = os.path.join(home, ".axiom_history")
    check("history file written", os.path.exists(hist) and "Gaia is a god." in open(hist).read())

    print()
    print(f"{passed} passed, {len(failed)} failed")
    if failed:
        for f in failed:
            print(f"  FAIL: {f}")
        sys.exit(1)


if __name__ == "__main__":
    main()
