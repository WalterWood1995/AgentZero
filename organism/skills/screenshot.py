#!/usr/bin/env python3
# skills/screenshot.py - the organism grabs the old PC's SCREEN for itself.
#
# Reads the old PC's VBE framebuffer back over UDP (the kernel's Y command) and saves
# it as a PNG - no camera, no photo. This closes the feedback loop: the Agent can now
# SEE what the bare-metal machine is rendering (the face, the HUD, a drawn image) and
# verify its own real-metal work instead of relying on someone photographing the screen.
#
# Usage:
#   python skills/screenshot.py [ip] [out.png] [--rows y0 y1]
#     ip defaults to 127.0.0.1 (QEMU). --rows grabs only y0..y1 for a fast partial grab.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW


def grab(ip="127.0.0.1", out="screen.png", y0=0, y1=None):
    hw = HW(ip)
    g = hw.geom()
    if g:
        print("framebuffer %dx%d pitch=%d bpp=%d" % g)
    img = hw.screenshot(out, y0=y0, y1=y1)
    print("saved %s (%dx%d)" % (out, img.size[0], img.size[1]))
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    ip = a[0] if a and a[0].count(".") == 3 else "127.0.0.1"
    rest = [x for x in a if x != ip]
    out = next((x for x in rest if x.endswith(".png")), "screen.png")
    y0, y1 = 0, None
    if "--rows" in rest:
        i = rest.index("--rows")
        y0, y1 = int(rest[i + 1]), int(rest[i + 2])
    grab(ip, out, y0, y1)
