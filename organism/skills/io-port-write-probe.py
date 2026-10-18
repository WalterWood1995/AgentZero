#!/usr/bin/env python3
# skills/io-port-write-probe.py - a GATED WRITE SKILL (the organism's smallest
# "operate hardware" skill: prove the gated write path works, harmlessly).
#
# ============================ WRITE PROPOSAL ============================
# TARGET:   I/O port 0x80 (the legacy POST / diagnostic port).
# WRITES:   one byte -> port 0x80, value 0xA5, via the kernel's gated `O` command.
# WHY SAFE: port 0x80 is the BIOS power-on-self-test code port. On a running system
#           it is write-only scratch - the chipset latches the byte onto the (absent)
#           POST card and nothing in the machine reads or acts on it. It is the
#           canonical "harmless I/O write" and was historically used as a short I/O
#           delay. It does not touch RAM, DMA, storage, or any device's control
#           state, and it is not the SATA/AHCI controller. There is nothing to undo.
# PROOF:    the kernel replies "write ok" for the confirmed write, and "write
#           aborted" when we deliberately omit the confirm byte - so we demonstrate
#           both that the write happened AND that the gate refuses an unconfirmed one.
# =======================================================================
#
# Run a DRY RUN (default - shows the plan and the gate self-test, writes nothing):
#   python skills/io-port-write-probe.py [ip]
# ARM it to actually issue the (harmless) write:
#   python skills/io-port-write-probe.py [ip] --arm
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW

PORT = 0x80
VALUE = 0xA5


def run(ip="127.0.0.1", armed=False):
    hw = HW(ip)
    v = hw.cpuid_vendor()
    print("kernel reachable: cpuid vendor = %r" % v)
    if not v:
        print("  no reply from the kernel; is it booted and on the network?")
        return False

    print("\nPLAN: gated outb  port 0x%02X <- 0x%02X  (harmless POST-code port)" % (PORT, VALUE))

    # Gate self-test (always safe): send the write WITHOUT the confirm byte and
    # show the kernel refuses it. Nothing is written.
    refused = hw.outb(PORT, VALUE, confirm=False)
    print("gate self-test (no confirm byte): kernel says %r" % refused)
    if refused and "abort" not in refused.lower():
        print("  WARNING: expected the kernel to abort an unconfirmed write!")

    if not armed:
        print("\nDRY RUN - not armed, no write issued. Re-run with --arm to operate.")
        return True

    ok = hw.outb(PORT, VALUE, confirm=True)
    print("\nARMED write (with confirm byte): kernel says %r" % ok)
    success = bool(ok and "ok" in ok.lower())
    print("RESULT:", "write path CONFIRMED" if success else "write did NOT confirm")
    return success


if __name__ == "__main__":
    a = sys.argv[1:]
    armed = ("--arm" in a) or (os.environ.get("ARM") == "1")
    a = [x for x in a if x != "--arm"]
    ip = a[0] if a and a[0].count(".") == 3 else "127.0.0.1"
    run(ip, armed)
