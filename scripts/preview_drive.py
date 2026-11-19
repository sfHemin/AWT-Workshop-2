#!/usr/bin/env python3
"""Drive the interactive `sf agent preview` TUI over a PTY and capture responses.

Usage:
  preview_drive.py <bundle_api_name> <target_org> <outdir> "utt1" "utt2" ...
"""
import os, sys, pty, select, time, re, struct, fcntl, termios

bundle = sys.argv[1]
org = sys.argv[2]
outdir = sys.argv[3]
utterances = sys.argv[4:]

cmd = [
    "sf", "agent", "preview",
    "--authoring-bundle", bundle,
    "--use-live-actions",
    "--target-org", org,
    "--output-dir", outdir,
]

ansi = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\].*?\x07|\x1b[=>]|[\x00-\x08\x0b\x0c\x0e-\x1f]")
def strip(b): return ansi.sub(b"", b).decode("utf-8", "replace")

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "160"; os.environ["LINES"] = "50"
    # Put the slave TTY in raw mode so CR (\r) is NOT translated to NL by the
    # line discipline — Ink's TextInput only submits on a real carriage return.
    try:
        import tty
        tty.setraw(0)
    except Exception:
        pass
    os.execvp(cmd[0], cmd)
    os._exit(1)
try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
except Exception:
    pass

acc = b""
def pump(seconds, until=None):
    """Read for up to `seconds`; stop early if `until` substring appears since last call."""
    global acc
    end = time.time() + seconds
    local = b""
    while time.time() < end:
        r,_,_ = select.select([fd], [], [], 0.3)
        if r:
            try: data = os.read(fd, 8192)
            except OSError: break
            if not data: break
            local += data; acc += data
            if until and until.encode() in local:
                # keep reading a touch to drain the full message
                time.sleep(1.5)
                try:
                    r2,_,_ = select.select([fd],[],[],0.3)
                    if r2:
                        d2=os.read(fd,8192); local+=d2; acc+=d2
                except OSError: pass
                return strip(local)
    return strip(local)

# Boot: wait until the welcome prompt is ready, then let the input focus settle.
pump(55, until="verify you")
pump(4)

for utt in utterances:
    # Type the line, then submit with its own settle so Ink registers the change.
    for ch in utt:
        os.write(fd, ch.encode()); time.sleep(0.02)
    time.sleep(1.5)
    os.write(fd, b"\r")
    time.sleep(0.5)
    os.write(fd, b"\r")   # a second newline is harmless if already submitted
    # Live Apex + LLM round trip; wait generously.
    pump(65)

# Exit and SAVE history so a JSON transcript is written to outdir.
try:
    os.write(fd, b"\x1b")  # ESC to trigger exit
    pump(4, until="Save chat history")
    os.write(fd, b"y")     # save
    os.write(fd, b"\r")
    pump(6)
except OSError:
    pass
try: os.close(fd)
except OSError: pass

# Dump the full cleaned transcript for the caller.
print("\n========== FULL CLEANED PTY OUTPUT ==========\n")
print(strip(acc))
