#!/usr/bin/env python3
# fb_screenshot.py - screenshot the old PC's screen by reading its framebuffer back over
# UDP (kernel 'Y<8hex off><4hex len>' -> raw BGRX bytes). ~2300 round trips for
# 1024x768x32, a few seconds; the live stream may keep running meanwhile.
#   PYTHONUTF8=1 python fb_screenshot.py [ip] [out.png] [--step N]   (N: read every Nth row)
import os, socket, struct, sys, time
import numpy as np
from PIL import Image

ip = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].count(".") == 3 else "192.168.178.114"
out = next((a for a in sys.argv[1:] if a.lower().endswith(".png")), os.path.join(os.environ.get("TEMP", "."), "asus_fb.png"))
step = int(sys.argv[sys.argv.index("--step") + 1]) if "--step" in sys.argv else 1
port = int(os.environ.get("AGENTZERO_PORT", "50000"))

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.5)
s.sendto(b"Q\0", (ip, port))
w, h, pitch, bpp = struct.unpack("<4I", s.recvfrom(64)[0][:16])
print("geometry %dx%d pitch %d" % (w, h, pitch), flush=True)
img = np.zeros((h, w, 4), dtype=np.uint8)
CH = 1400 // 4 * 4
t0 = time.time(); lost = 0
for y in range(0, h, step):
    row = bytearray()
    x = 0
    while x < w * 4:
        n = min(CH, w * 4 - x)
        got = None
        for _ in range(4):
            s.sendto(b"Y%08X%04X" % (y * pitch + x, n), (ip, port))
            try:
                d, _ = s.recvfrom(2048)
                if len(d) == n:
                    got = d; break
            except (socket.timeout, OSError):
                pass
        if got is None:
            lost += 1; got = bytes(n)
        row += got; x += n
    img[y] = np.frombuffer(bytes(row), dtype=np.uint8).reshape(w, 4)
    if step > 1:
        for k in range(1, step):
            if y + k < h:
                img[y + k] = img[y]
rgb = img[..., [2, 1, 0]]
Image.fromarray(rgb).save(out)
print("saved %s in %.1fs (lost chunks %d)" % (out, time.time() - t0, lost))
