#!/usr/bin/env python3
# ascii_cam_wait_real.py - wait for the real Asus (PXE-booted pxe.img) to answer on
# UDP, then start ascii_cam against it. Lets the user just power the machine on.
#   PYTHONUTF8=1 python ascii_cam_wait_real.py [ip] [minutes] [ascii_cam args...]
import os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ip = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].count(".") == 3 else "192.168.178.114"
mins = float(sys.argv[2]) if len(sys.argv) > 2 else 15
extra = sys.argv[3:] or ["--layout", "brain", "--fps", "10", "--mirror", "--repeat", "2", "--duration", "900"]

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.0)
t0 = time.time()
print("waiting for %s (up to %.0f min)..." % (ip, mins), flush=True)
while time.time() - t0 < mins * 60:
    try:
        s.sendto(b"Q\0", (ip, 50000))
        d, _ = s.recvfrom(64)
        if len(d) >= 16:
            print("kernel up after %.0fs, geometry reply %d B" % (time.time() - t0, len(d)), flush=True)
            break
    except (socket.timeout, OSError):
        pass
    time.sleep(2)
else:
    sys.exit("no answer from %s" % ip)
time.sleep(3)                                              # let the boot animation finish
cmd = [sys.executable, os.path.join(HERE, "ascii_cam.py"), ip] + extra
print("starting:", " ".join(cmd), flush=True)
sys.exit(subprocess.call(cmd, env=dict(os.environ, PYTHONUTF8="1")))
