#!/usr/bin/env python3
# Boot AgentZero in QEMU (PXE + UDP), draw the Einstein face over UDP, screenshot.
import json, os, socket, subprocess, sys, tempfile, threading, time, shutil
import face as facemod
import ascii_art

QEMU = os.environ.get("QEMU", "qemu-system-i386")
HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 55570
tftp = os.path.join(tempfile.gettempdir(), "jev_tftp")
os.makedirs(tftp, exist_ok=True)
shutil.copy(os.path.join(HERE, "pxe.img"), os.path.join(tftp, "pxe.img"))
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "jev_face.png")

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

time.sleep(11.0)                                 # boot + rain + net_loop ready
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
lines = ascii_art.render(os.path.join(HERE, "einstein.jpg"), facemod.W)
disp = [" " * facemod.PAD + ln for ln in lines]
facemod.blast(sock, "127.0.0.1", b"X")
row = 0
while row < len(disp):
    block = disp[row:row + facemod.CHUNK]
    facemod.blast(sock, "127.0.0.1", ("B%02X\n" % row).encode() + "\n".join(block).encode("latin1"))
    row += facemod.CHUNK
facemod.blast(sock, "127.0.0.1", ("B%02X\n  > I am AgentZero, on bare metal." % (len(disp) + 1)).encode())
time.sleep(0.5)

f.write((json.dumps({"execute": "screendump",
         "arguments": {"filename": out.replace("\\", "\\\\"), "format": "png"}}) + "\n").encode())
f.readline(); time.sleep(0.5)
p.terminate()
try: p.wait(timeout=3)
except subprocess.TimeoutExpired: p.kill()
print(out)
