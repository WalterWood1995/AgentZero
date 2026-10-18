#!/usr/bin/env python3
# PXE-boot AgentZero in QEMU, inject keystrokes via QMP (PS/2 keyboard), and
# screenshot to verify the kernel's keyboard driver echoes typed text.
import json, os, socket, subprocess, sys, tempfile, threading, time, shutil

QEMU = os.environ.get("QEMU", "qemu-system-i386")
HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 55580
tftp = os.path.join(tempfile.gettempdir(), "jev_tftp")
os.makedirs(tftp, exist_ok=True)
shutil.copy(os.path.join(HERE, "pxe.img"), os.path.join(tftp, "pxe.img"))
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "jev_kbd.png")

p = subprocess.Popen(
    [QEMU, "-boot", "n",
     "-netdev", "user,id=n0,tftp=%s,bootfile=pxe.img,hostfwd=udp::50000-:50000" % tftp,
     "-device", "e1000,netdev=n0", "-display", "none", "-no-reboot",
     "-qmp", "tcp:127.0.0.1:%d,server,nowait" % PORT],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

s = None
for _ in range(60):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=1); break
    except OSError:
        time.sleep(0.1)
f = s.makefile("rwb", buffering=0)
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()

time.sleep(12.0)                                 # boot + animation + net_loop ready

def key(q):
    f.write((json.dumps({"execute": "send-key",
             "arguments": {"keys": [{"type": "qcode", "data": q}]}}) + "\n").encode())
    f.readline(); time.sleep(0.08)

for q in ["h", "e", "l", "l", "o", "spc", "a", "g", "e", "n", "t", "z", "e", "r", "o"]:
    key(q)
time.sleep(0.3)
f.write((json.dumps({"execute": "screendump",
         "arguments": {"filename": out.replace("\\", "\\\\"), "format": "png"}}) + "\n").encode())
f.readline(); time.sleep(0.5)
p.terminate()
try: p.wait(timeout=3)
except subprocess.TimeoutExpired: p.kill()
print(out)
