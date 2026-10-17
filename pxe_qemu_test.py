#!/usr/bin/env python3
# pxe_qemu_test.py - boot pxe.img via QEMU's built-in PXE (SLIRP TFTP+BOOTP),
# proving the network-boot image works before touching the real Asus.
# Captures COM1 so we can see the kernel's PCI scan / banner.
import os, subprocess, sys, tempfile, threading, time, shutil

QEMU = os.environ.get("QEMU", "qemu-system-i386")  # full path, or set the QEMU env var
HERE = os.path.dirname(os.path.abspath(__file__))
tftp = os.path.join(tempfile.gettempdir(), "jev_tftp")
os.makedirs(tftp, exist_ok=True)
shutil.copy(os.path.join(HERE, "pxe.img"), os.path.join(tftp, "pxe.img"))

p = subprocess.Popen(
    [QEMU, "-boot", "n",
     "-netdev", "user,id=n0,tftp=%s,bootfile=pxe.img" % tftp,
     "-device", "e1000,netdev=n0",
     "-serial", "stdio", "-display", "none", "-no-reboot"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, bufsize=0)

out = bytearray()
def rd():
    while True:
        b = p.stdout.read(1)
        if not b:
            break
        out.extend(b)
threading.Thread(target=rd, daemon=True).start()

time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 10)
p.terminate()
try:
    p.wait(timeout=3)
except subprocess.TimeoutExpired:
    p.kill()
sys.stdout.write(bytes(out).decode("latin1"))
