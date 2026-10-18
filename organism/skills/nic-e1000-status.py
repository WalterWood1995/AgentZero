#!/usr/bin/env python3
"""Read-only: print the Intel e1000 NIC (00:03.0) identity + link/speed/duplex status."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW  # noqa: E402

BUS, DEV, FN = 0, 3, 0


def main():
    ip = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    hw = HW(ip)

    # --- identity from PCI config space (full dwords are reliable here) ---
    vid = hw.pci(BUS, DEV, FN, 0x00)
    cls = hw.pci(BUS, DEV, FN, 0x08)
    bar0 = hw.pci(BUS, DEV, FN, 0x10)
    bar1 = hw.pci(BUS, DEV, FN, 0x14)
    irq = hw.pci(BUS, DEV, FN, 0x3C)
    if vid is None:
        print("NIC 00:03.0: no reply from kernel at %s" % ip)
        return 1

    vendor, device = vid & 0xFFFF, (vid >> 16) & 0xFFFF
    classcode = (cls >> 8) & 0xFFFFFF if cls else 0
    mmio = bar0 & 0xFFFFFFF0          # BAR0 is a 32-bit memory BAR
    ioaddr = bar1 & 0xFFFFFFFC        # BAR1 is an I/O BAR
    print("NIC 00:03.0  %04X:%04X  class %06X  (Intel e1000 / 82540EM)"
          % (vendor, device, classcode))
    print("  BAR0 MMIO = 0x%08X   BAR1 I/O = 0x%04X   IRQ = %d"
          % (mmio, ioaddr, (irq or 0) & 0xFF))

    # --- live status from MMIO (kernel's mem reader yields the low byte of each reg) ---
    status_lo = hw.mem(mmio + 0x08, 1)   # STATUS @ BAR0+0x08
    ral_lo = hw.mem(mmio + 0x5400, 1)    # RAL0  @ BAR0+0x5400 (MAC[0])
    rah_lo = hw.mem(mmio + 0x5404, 1)    # RAH0  @ BAR0+0x5404 (MAC[4])
    if status_lo:
        s = status_lo[0]
        link = "UP" if (s & 0x02) else "DOWN"
        duplex = "full" if (s & 0x01) else "half"
        speed = {0: "10", 1: "100", 2: "1000", 3: "1000"}[(s >> 6) & 0x3]
        print("  STATUS=0x%02X  link=%s  speed=%s Mb/s  duplex=%s"
              % (s, link, speed, duplex))
    if ral_lo and rah_lo:
        print("  MAC[0]=0x%02X MAC[4]=0x%02X  (e1000 default 52:54:00:12:34:56)"
              % (ral_lo[0], rah_lo[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
