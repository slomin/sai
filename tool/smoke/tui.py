#!/usr/bin/env python3
"""Drives the TUI in a pseudo-terminal for a smoke, without tmux.

    tool/smoke/tui.py <scratch-dir> <steps.json>

Steps are a JSON list of [kind, arg, seconds]:
  ["wait", "text", 60]   wait until the screen shows text (whitespace ignored)
  ["send", "\t", 0.5]    write keys; "\r" is Enter, "\x1b" Esc, "\x03" Ctrl+C
  ["snap", "name", 0]    save the stripped screen text as <dir>/<name>.txt
  ["sleep", 2, 0]        just wait

Runs `dart run apps/sai_tui/bin/sai_tui.dart` (SAI_TUI_ENTRY names another
entry point, e.g. bin/sai_tui-dev.dart; SAI_TUI_BIN a compiled binary)
with SAI_ARCHIVE_ROOT and SAI_SETTINGS_FILE under
<scratch-dir>, a 100x30 terminal, and always
kills the process at the end. Prints one line per step.

Two things a real terminal does that the nocterm tester does not: keys
arrive as a byte stream, chunked by read (so each key is written on its
own — a string and its Enter in one chunk parse differently), and
the screen is repainted cell by cell — only the cells that changed — so
the output is replayed into a small screen model and text is matched on
the rendered rows, whitespace collapsed. nocterm paints the rows below
the list only after the first key arrives, so wait for the list, send
a key (Tab is harmless), then wait for the footer.
"""
import codecs, fcntl, json, os, pty, re, select, signal, struct, sys, termios, time

ROWS, COLS = 30, 100
# One key: a CSI sequence (arrows) or a single character (a lone Esc too).
KEY = re.compile(r'\x1b\[[0-9;]*[@-~]|.', re.S)
SEQ = re.compile(r'\x1b\[([0-9;?]*)([ -/]*)([@-~])|\x1b[()][A-Z0-9]|\x1b[=>78]|\x1b\][^\x07]*\x07')


class Screen:
    """Enough of a VT100 to render nocterm: cursor moves, erases, text."""

    def __init__(self):
        self.rows = [[' '] * COLS for _ in range(ROWS)]
        self.r = self.c = 0
        self.pending = ''
        # A read can split a multibyte character; decode across chunks.
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')

    def feed(self, data):
        text = self.pending + self.decoder.decode(data)
        self.pending = ''
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == '\x1b':
                m = SEQ.match(text, i)
                if m is None:
                    if len(text) - i < 16:
                        self.pending = text[i:]
                        return
                    i += 1
                    continue
                if m.group(3):
                    self.csi(m.group(1), m.group(3))
                i = m.end()
                continue
            i += 1
            if ch == '\r':
                self.c = 0
            elif ch == '\n':
                self.r = min(ROWS - 1, self.r + 1)
            elif ch == '\b':
                self.c = max(0, self.c - 1)
            elif ch >= ' ':
                if self.c < COLS and self.r < ROWS:
                    self.rows[self.r][self.c] = ch
                self.c += 1

    def csi(self, params, final):
        nums = [int(n) if n else 0 for n in params.lstrip('?').split(';')] if params.strip('?') else []
        n = nums[0] if nums else 0
        if final in 'Hf':
            self.r = max(0, (nums[0] if nums else 1) - 1)
            self.c = max(0, (nums[1] if len(nums) > 1 else 1) - 1)
        elif final == 'A': self.r = max(0, self.r - max(1, n))
        elif final == 'B': self.r = min(ROWS - 1, self.r + max(1, n))
        elif final == 'C': self.c += max(1, n)
        elif final == 'D': self.c = max(0, self.c - max(1, n))
        elif final == 'E': self.r, self.c = min(ROWS - 1, self.r + max(1, n)), 0
        elif final == 'F': self.r, self.c = max(0, self.r - max(1, n)), 0
        elif final == 'G': self.c = max(0, (n or 1) - 1)
        elif final == 'd': self.r = max(0, (n or 1) - 1)
        elif final == 'J':
            if n == 2 or n == 3:
                self.rows = [[' '] * COLS for _ in range(ROWS)]
            elif n == 0:
                for rr in range(self.r, ROWS):
                    start = self.c if rr == self.r else 0
                    self.rows[rr][start:] = [' '] * (COLS - start)
        elif final == 'K':
            if n == 0: self.rows[self.r][self.c:] = [' '] * (COLS - self.c)
            elif n == 2: self.rows[self.r] = [' '] * COLS

    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.rows)


def main(scratch, steps):
    env = dict(os.environ, SAI_ARCHIVE_ROOT=f'{scratch}/archive',
               SAI_SETTINGS_FILE=f'{scratch}/settings.json', TERM='xterm-256color')
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(root)
        binary = os.environ.get('SAI_TUI_BIN')
        if binary:
            os.execvpe(binary, [binary], env)
        entry = os.environ.get('SAI_TUI_ENTRY', 'apps/sai_tui/bin/sai_tui.dart')
        os.execvpe('dart', ['dart', 'run', entry], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
    screen = Screen()

    def read(seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    screen.feed(os.read(fd, 65536))
                except OSError:
                    return

    def wait(text, seconds):
        needle = re.sub(r'\s+', '', text)
        end = time.time() + seconds
        while time.time() < end:
            read(0.5)
            if needle in re.sub(r'\s+', '', screen.text()):
                return True
        return False

    ok = True
    try:
        for kind, arg, seconds in steps:
            if kind == 'wait':
                hit = wait(arg, seconds)
                ok &= hit
                print(f'{"ok  " if hit else "FAIL"} wait {arg!r}', flush=True)
            elif kind == 'send':
                # One key per write, as a hand on a keyboard: a whole
                # string in one read is parsed differently by nocterm
                # (an Enter after text in the same chunk can be lost).
                for key in KEY.findall(arg):
                    os.write(fd, key.encode())
                    read(0.03)
                read(seconds)
                print(f'ok   send {arg!r}', flush=True)
            elif kind == 'snap':
                with open(f'{scratch}/{arg}.txt', 'w') as out:
                    out.write(screen.text())
                print(f'ok   snap {arg}', flush=True)
            elif kind == 'sleep':
                read(arg)
    finally:
        os.write(fd, b'\x03')
        read(1)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], json.load(open(sys.argv[2]))))
