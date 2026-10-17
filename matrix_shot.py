#!/usr/bin/env python3
# matrix_shot.py - boot the kernel in QEMU, drive a curated command batch over
# serial, then grab the VGA text screen (bright green on black) as a PNG via the
# QMP screendump command. Writes the PNG to an ASCII path (the QEMU Windows exe
# chokes on CJK output filenames), so pass an explicit --out if you want.
#
# Captures TWO frames: one mid-rain and one of the terminal session.
# Usage: python3 matrix_shot.py [terminal_out.png] [rain_out.png]

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

QEMU = os.environ.get("QEMU", "qemu-system-i386")  # full path, or set the QEMU env var
DISK = "disk.img"
QMP_PORT = 55556

# Curated so the whole session fits on the 80x25 screen without scrolling away.
BATCH = ["C", "F", "I0064", "T", "P0000000", "M00007DFC04", "O0080AB!", "?"]


def shot(f, path):
    req = {"execute": "screendump",
           "arguments": {"filename": path.replace("\\", "\\\\"), "format": "png"}}
    f.write((json.dumps(req) + "\n").encode())
    f.readline()


def main():
    tmp = tempfile.gettempdir()
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tmp, "jev_matrix.png")
    rain_out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(tmp, "jev_rain.png")

    p = subprocess.Popen(
        [QEMU, "-drive", "format=raw,file=%s" % DISK,
         "-serial", "stdio", "-display", "none", "-no-reboot",
         "-qmp", "tcp:127.0.0.1:%d,server,nowait" % QMP_PORT],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, bufsize=0)

    def reader():
        while True:
            b = p.stdout.read(1)
            if not b:
                break

    threading.Thread(target=reader, daemon=True).start()

    # Connect QMP (retry until the server socket is up).
    s = None
    for _ in range(50):
        try:
            s = socket.create_connection(("127.0.0.1", QMP_PORT), timeout=1)
            break
        except OSError:
            time.sleep(0.1)
    if s is None:
        p.kill()
        raise SystemExit("could not connect to QMP")
    f = s.makefile("rwb", buffering=0)
    f.readline()                                   # QMP greeting
    f.write(b'{"execute":"qmp_capabilities"}\n')
    f.readline()                                   # ack

    time.sleep(2.5)                                # mid-rain
    shot(f, rain_out)                              # frame 1: digital rain

    time.sleep(2.5)                                # let the ~4.3s rain finish
    for cmd in BATCH:                              # first byte also skips any rain left
        p.stdin.write(cmd.encode() + b"\n")
        p.stdin.flush()
        time.sleep(0.6)
    time.sleep(0.4)
    shot(f, out)                                   # frame 2: terminal session
    time.sleep(0.4)

    p.terminate()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill()
    print(rain_out)
    print(out)


if __name__ == "__main__":
    main()
