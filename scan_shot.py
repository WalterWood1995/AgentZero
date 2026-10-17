#!/usr/bin/env python3
# scan_shot.py - boot the kernel in QEMU and screenshot the PCI self-scan
# screen (rain -> PCI device table -> prompt). No serial input needed; this is
# exactly what a real machine would show for a photo. Usage: scan_shot.py [out.png]
import json, os, socket, subprocess, sys, tempfile, threading, time

QEMU = os.environ.get("QEMU", "qemu-system-i386")  # full path, or set the QEMU env var
PORT = 55558

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "jev_pciscan.png")
delay = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0   # boot + idle before shot

p = subprocess.Popen(
    [QEMU, "-drive", "format=raw,file=disk.img", "-serial", "stdio",
     "-display", "none", "-no-reboot",
     "-qmp", "tcp:127.0.0.1:%d,server,nowait" % PORT],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL, bufsize=0)
threading.Thread(target=lambda: [p.stdout.read(1) for _ in iter(int, 1)], daemon=True).start()

s = None
for _ in range(50):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=1)
        break
    except OSError:
        time.sleep(0.1)
f = s.makefile("rwb", buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n')
f.readline()

time.sleep(delay)                                  # rain intro + scan + idle ambient rain
req = {"execute": "screendump",
       "arguments": {"filename": out.replace("\\", "\\\\"), "format": "png"}}
f.write((json.dumps(req) + "\n").encode())
f.readline()
time.sleep(0.5)
p.terminate()
try:
    p.wait(timeout=3)
except subprocess.TimeoutExpired:
    p.kill()
print(out)
