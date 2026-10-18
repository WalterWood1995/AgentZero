#!/usr/bin/env python3
"""Read-only: print the VGA display controller's identity + framebuffer base (00:02.0)."""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW  # noqa: E402

BUS, DEV, FN = 0, 2, 0


def main():
    ip = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    hw = HW(ip)

    ids = hw.pci(BUS, DEV, FN, 0x00)
    cls = hw.pci(BUS, DEV, FN, 0x08)
    cmd = hw.pci(BUS, DEV, FN, 0x04)
    bar0 = hw.pci(BUS, DEV, FN, 0x10)
    bar2 = hw.pci(BUS, DEV, FN, 0x18)
    if ids is None or bar0 is None:
        print("no reply from kernel at %s (lossy link -- retry)" % ip)
        return 1

    vendor, device = ids & 0xFFFF, (ids >> 16) & 0xFFFF
    classcode = (cls >> 8) & 0xFFFFFF if cls else 0
    command = cmd & 0xFFFF if cmd else 0
    fb_base = bar0 & ~0xF          # strip the 4 low type bits -> LFB physical base
    mmio_base = bar2 & ~0xF if bar2 else 0

    print("VGA display controller  %02x:%02x.%d" % (BUS, DEV, FN))
    print("  vendor:device = %04x:%04x  (QEMU/Bochs stdvga)" % (vendor, device))
    print("  class         = %06x  (VGA-compatible display)" % classcode)
    print("  command       = 0x%04x  (I/O=%d MEM=%d)"
          % (command, command & 1, (command >> 1) & 1))
    print("  BAR0 raw      = 0x%08X  -> framebuffer base = 0x%08X"
          % (bar0, fb_base))
    print("                   (32-bit, prefetchable=%d) -- the linear framebuffer"
          % ((bar0 >> 3) & 1))
    print("  BAR2 raw      = 0x%08X  -> MMIO regs base   = 0x%08X  (Bochs DISPI)"
          % (bar2 or 0, mmio_base))
    print("  Draw: pixel(x,y) at fb_base + y*pitch + x*4  (32bpp XRGB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
