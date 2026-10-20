#!/usr/bin/env python3
# skills/reboot.py - the organism REBOOTS the old PC for itself.
#
# Sends the kernel's K! command, which pulses the 8042 reset line (CPU reset). The
# machine resets and, because its BIOS boot order is network-first, re-PXE-boots the
# latest image the dev PC is serving. So the Agent can iterate on the bare-metal kernel
# without anyone pressing the power button: build -> reboot() -> it comes back on the
# new kernel. Pair with skills/screenshot.py for a fully self-served real-metal loop.
#
# Usage:
#   python skills/reboot.py [ip]      (ip defaults to 127.0.0.1 / QEMU)
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW


def reboot(ip="127.0.0.1", wait=0):
    hw = HW(ip)
    print("rebooting the old PC (K!) - it will re-PXE-boot the served image")
    hw.reboot()
    if wait:
        time.sleep(wait)
    return True


if __name__ == "__main__":
    a = sys.argv[1:]
    ip = a[0] if a and a[0].count(".") == 3 else "127.0.0.1"
    reboot(ip)
