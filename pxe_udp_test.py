#!/usr/bin/env python3
# pxe_udp_test.py - boot pxe.img via QEMU PXE, then drive the kernel's Agent UDP
# command channel: send commands to it over UDP and print the replies. QEMU
# SLIRP forwards host udp :50000 to the guest's :50000 (the kernel's port).
import os, socket, subprocess, sys, tempfile, threading, time, shutil

QEMU = os.environ.get("QEMU", "qemu-system-i386")  # full path, or set the QEMU env var
HERE = os.path.dirname(os.path.abspath(__file__))
tftp = os.path.join(tempfile.gettempdir(), "jev_tftp")
os.makedirs(tftp, exist_ok=True)
shutil.copy(os.path.join(HERE, "pxe.img"), os.path.join(tftp, "pxe.img"))

p = subprocess.Popen(
    [QEMU, "-boot", "n",
     "-netdev", "user,id=n0,tftp=%s,bootfile=pxe.img,hostfwd=udp::50000-:50000" % tftp,
     "-device", "e1000,netdev=n0",
     "-serial", "stdio", "-display", "none", "-no-reboot"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, bufsize=0)

serial = bytearray()
def rd():
    while True:
        b = p.stdout.read(1)
        if not b:
            break
        serial.extend(b)
threading.Thread(target=rd, daemon=True).start()

boot = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
time.sleep(boot)                                    # PXE load + rain + UDP_OPEN

cmds = sys.argv[2:] or ["C", "F", "I0064", "P0000000", "M00007DFC04", "?"]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3.0)
print("=== serial (boot) ===")
sys.stdout.write(bytes(serial).decode("latin1"))
print("\n=== UDP command channel ===")
for c in cmds:
    try:
        s.sendto(c.encode(), ("127.0.0.1", 50000))
        data, _ = s.recvfrom(4096)
        print("CMD %-12s -> %s" % (c, repr(data.decode("latin1"))))
    except socket.timeout:
        print("CMD %-12s -> (timeout, no reply)" % c)
    time.sleep(0.3)

p.terminate()
try:
    p.wait(timeout=3)
except subprocess.TimeoutExpired:
    p.kill()
