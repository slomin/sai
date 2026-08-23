#!/usr/bin/env python3
"""Drive the spike under a pseudo-terminal and report what it painted.

Only changed cells are written, so probe for single words: a phrase
spanning unchanged cells never appears contiguously in the capture.

Evidence for DECISION.md criterion 1: nocterm paints cell diffs, so a
whole session emits very few full-screen repositions (ESC[H). Run from
spikes/nocterm_spike:  python3 tool/pty_probe.py
"""
import fcntl
import os
import pty
import re
import select
import struct
import termios
import time

ESC = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]")
CURSOR_SHOW, CURSOR_HIDE = b"\x1b[?25h", b"\x1b[?25l"

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp("dart", ["dart", "run", "bin/spike.dart"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
out = b""


def read(seconds):
    global out
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return


def wait_for(text, timeout=30):
    end = time.time() + timeout
    while time.time() < end and text.encode() not in ESC.sub(b"", out):
        read(0.2)
    return text.encode() in ESC.sub(b"", out)


print("app ready:", wait_for("Ask sai"))
read(1)
os.write(fd, b"j")
read(0.3)
os.write(fd, b"\r")  # ask about task 2; the reply streams
t0 = len(out)
print("reply streamed:", wait_for("reorder"))
stream_bytes = len(out) - t0
os.write(fd, b"\t")
read(0.5)
after_tab = len(out)
os.write(fd, "żółć 🚀 test".encode())
read(0.5)
print("utf-8 echoed:", "żółć 🚀 test".encode() in ESC.sub(b"", out))
os.write(fd, b"\t")  # back to the list: the IME cursor should hide
read(0.5)
tail = out[after_tab:]
print("cursor hidden after Tab back to list:",
      tail.rfind(CURSOR_HIDE) > tail.rfind(CURSOR_SHOW))
os.write(fd, b"\x03")
read(1.5)
_, status = os.waitpid(pid, 0)
print("exit status:", status >> 8)
print("full-screen repositions (ESC[H):", out.count(b"\x1b[H"),
      "| bytes during stream:", stream_bytes,
      "| total bytes:", len(out))
