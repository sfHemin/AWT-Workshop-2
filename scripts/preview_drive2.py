#!/usr/bin/env python3
"""Drive `sf agent preview` over a PTY, submitting one utterance at a time and
waiting for the agent's reply before sending the next.

Usage: preview_drive2.py <bundle_api_name> <target_org> <outdir> "utt1" "utt2" ...
"""
import os, sys, pty, select, time, re, struct, fcntl, termios

bundle, org, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
utterances = sys.argv[4:]

cmd = ["sf", "agent", "preview", "--authoring-bundle", bundle,
       "--use-live-actions", "--target-org", org, "--output-dir", outdir]

ansi = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\].*?\x07|\x1b[=>]|[\x00-\x08\x0b\x0c\x0e-\x1f]")
def strip(b): return ansi.sub(b"", b).decode("utf-8", "replace")

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "160"; os.environ["LINES"] = "50"
    # Raw mode on the slave TTY so CR (\r) is NOT translated to NL — Ink's
    # TextInput only submits on a real carriage return.
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
                time.sleep(1.2)
                try:
                    r2,_,_ = select.select([fd],[],[],0.3)
                    if r2:
                        d2=os.read(fd,8192); local+=d2; acc+=d2
                except OSError: pass
                break
    return strip(local)

def count_agent_msgs():
    return strip(acc).count("Ascend_Clinics_Assistant 11/")

# Boot.
pump(70, until="verify you")
pump(3)

for i, utt in enumerate(utterances):
    before = count_agent_msgs()
    for ch in utt:
        os.write(fd, ch.encode()); time.sleep(0.015)
    time.sleep(2.0)
    os.write(fd, b"\r")
    # Wait until a NEW agent message block appears (or timeout).
    end = time.time() + 90
    while time.time() < end:
        pump(2)
        if count_agent_msgs() > before:
            # drain the tail of the response
            pump(3)
            break

# Exit + save history.
try:
    os.write(fd, b"\x1b")
    pump(5, until="Save chat history")
    os.write(fd, b"y"); os.write(fd, b"\r")
    pump(6)
except OSError:
    pass
try: os.close(fd)
except OSError: pass

print("\n========== FULL CLEANED PTY OUTPUT ==========\n")
print(strip(acc))
