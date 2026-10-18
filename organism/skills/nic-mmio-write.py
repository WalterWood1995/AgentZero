#!/usr/bin/env python3
# skills/nic-mmio-write.py - a GATED WRITE SKILL: the organism's first real
# OPERATION of a device via MMIO. It writes live registers of the Intel 82540EM
# (e1000) NIC at 00:03.0 through its BAR0 block - a genuine, SAFE, reversible step
# toward the RX driver sketched in knowledge/nic-e1000.md - without ever enabling
# the receiver or starting DMA.
#
# ============================ WRITE PROPOSAL ============================
# TARGET:   e1000 NIC 00:03.0 (8086:100E), MMIO register block at BAR0 = 0xFEBC0000.
#           The skill re-checks vendor:device over PCI and refuses if it is not this
#           NIC, so it can never write MMIO it does not recognise.
#
# ARMED WRITES (proven safe + reliable in QEMU; all via the gated `W` dword command
#   with the `!` confirm byte):
#   1. MTA[0]  @ 0xFEBC5200 <- 0x000000A5 (sentinel)  then <- 0x0 (restore)
#        MTA = Multicast Table Array, 128 plain read/write filter words. With the
#        receiver DISABLED they are inert storage: writing one changes no behaviour
#        and starts no DMA. We write a sentinel, read its low byte back to PROVE the
#        MMIO write path reaches the device register, then clear it -> fully reversible.
#   2. RDLEN   @ 0xFEBC2808 <- 0x0000F000  (RX descriptor ring length, 61440 bytes)
#        A plain R/W register; staging the ring length while RX is off is inert (the
#        NIC acts on it only once RCTL.EN is set, which this skill never does).
#        Verified: writing it leaves the NIC healthy (STATUS still link-up).
#
# WHY SAFE: no enable bit, no reset bit, no bus-master toggling; the receiver stays
#   off so no DMA ever starts; every armed write is to a documented plain R/W register
#   of a device the organism already understands. NOT the SATA/AHCI controller. The
#   sentinel is undone; RDLEN is inert until RCTL.EN (never set here). STATUS (link
#   up = low byte 0x83) is checked before and after to confirm the NIC is healthy.
#
# PROOF:  MTA[0] reads back 0xA5 after the write and 0x00 after the restore; the
#   unconfirmed write is refused by the kernel; STATUS stays 0x83 throughout.
#
# ----- NOT ARMED (held back by the review/arm-in-sandbox gate) -----
#   Staging the RX ring BASE registers RDBAL (0x2800) / RDBAH (0x2804) was proposed
#   as the next driver step, but arming it in QEMU first (exactly what this gate is
#   for) showed that writing RDBAL = 0x00040000 WEDGES the kernel: the write acks,
#   then the machine stops answering (even CPUID times out). Root cause not yet
#   understood (likely a QEMU e1000 ring-recompute side effect). Because it is not
#   understood and not safe, it stays a PROPOSAL and is never issued - and so it
#   never reaches real hardware. See knowledge/nic-e1000.md and SHOW_RING_PLAN below.
# =======================================================================
#
# DRY RUN (default - prints the plan + gate self-test, writes nothing):
#   python skills/nic-mmio-write.py [ip]
# ARM the safe operation:
#   python skills/nic-mmio-write.py [ip] --arm
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW

BAR0   = 0xFEBC0000          # e1000 MMIO base (from knowledge/nic-e1000.md)
STATUS = BAR0 + 0x0008       # device status (bit1 LU = link up); low byte 0x83
MTA0   = BAR0 + 0x5200       # multicast table array entry 0 (inert while RX off)
RDLEN  = BAR0 + 0x2808       # RX descriptor ring length (bytes)
RDBAL  = BAR0 + 0x2800       # RX ring base low  - UNSAFE here (wedges, see header)
RDBAH  = BAR0 + 0x2804       # RX ring base high

RING_LEN = 0x0000F000        # staged RX ring length
SENTINEL = 0x000000A5

# The command link is lossy (QEMU SLIRP, far worse on the real NIC/UNDI stack); a
# long unpaced burst drops replies at the tail, so we pace writes a little.
PACE = 0.12


def _w(hw, addr, dword):
    time.sleep(PACE)
    return hw.write32(addr, dword)


def run(ip="127.0.0.1", armed=False):
    hw = HW(ip)

    vid = hw.pci(0, 3, 0, 0)
    print("PCI 00:03.0 vendor:device = 0x%08X" % (vid or 0))
    if vid != 0x100E8086:
        print("  NOT the known 8086:100E e1000 - refusing to write unknown MMIO.")
        return False

    before = hw.mmio_lowbyte(STATUS)
    print("e1000 STATUS low byte before = 0x%02X (0x83 = link up, full duplex, 1Gb)"
          % (before or 0))

    print("\nARMED PLAN (gated `W` dword writes; RX stays DISABLED - no DMA):")
    print("  MTA[0]  0x%08X <- 0x%08X sentinel, then restore 0x0" % (MTA0, SENTINEL))
    print("  RDLEN   0x%08X <- 0x%08X" % (RDLEN, RING_LEN))
    print("NOT ARMED (proposal held back - wedges the kernel in QEMU):")
    print("  RDBAL   0x%08X <- ring base   (UNSAFE: see skill header)" % RDBAL)
    print("  RDBAH   0x%08X <- ring base hi" % RDBAH)

    # Gate self-test (safe): an unconfirmed write must be refused. Nothing written.
    refused = hw.write32(MTA0, SENTINEL, confirm=False)
    print("\ngate self-test (no confirm byte): kernel says %r" % refused)
    if refused and "abort" not in refused.lower():
        print("  WARNING: expected the kernel to abort an unconfirmed write!")

    if not armed:
        print("\nDRY RUN - not armed, no write issued. Re-run with --arm to operate.")
        return True

    ok = True

    # 1. Prove the MMIO write path with a reversible sentinel in MTA[0].
    print("\n-- MMIO write proof (MTA[0], reversible) --")
    print("  write sentinel:", _w(hw, MTA0, SENTINEL))
    rb = hw.mmio_lowbyte(MTA0)
    print("  read back MTA[0] low byte = 0x%02X (expect 0xA5)" % (rb or 0))
    ok &= (rb == (SENTINEL & 0xFF))
    print("  restore 0x0  :", _w(hw, MTA0, 0))
    rb = hw.mmio_lowbyte(MTA0)
    print("  read back MTA[0] low byte = 0x%02X (expect 0x00)" % (rb or 0))
    ok &= (rb == 0)

    # 2. Stage the RX descriptor ring LENGTH (a safe step; RX stays off).
    print("\n-- stage RX ring length (RCTL.EN never set, so NIC stays idle) --")
    print("  RDLEN :", _w(hw, RDLEN, RING_LEN))

    time.sleep(PACE)
    after = hw.mmio_lowbyte(STATUS)
    print("\ne1000 STATUS low byte after = 0x%02X (unchanged 0x83 = NIC still healthy)"
          % (after or 0))
    ok &= (after == before)

    print("\nRESULT:", "OPERATION CONFIRMED (writes landed, NIC healthy, RX left off)"
          if ok else "something did not verify - inspect output above")
    return ok


if __name__ == "__main__":
    a = sys.argv[1:]
    armed = ("--arm" in a) or (os.environ.get("ARM") == "1")
    a = [x for x in a if x != "--arm"]
    ip = a[0] if a and a[0].count(".") == 3 else "127.0.0.1"
    run(ip, armed)
