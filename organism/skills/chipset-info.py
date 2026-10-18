#!/usr/bin/env python3
"""Read-only: print the i440FX host bridge + PIIX4 ACPI/PM chipset identity & key regs."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW  # noqa: E402


def _dw(hw, bus, dev, fn, off):
    v = hw.pci(bus, dev, fn, off)
    return v if v is not None else 0


def main():
    ip = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    hw = HW(ip)

    # --- 00:00.0 i440FX host bridge ---
    hb_id = _dw(hw, 0, 0, 0, 0x00)
    hb_cmd = _dw(hw, 0, 0, 0, 0x04)
    hb_cls = _dw(hw, 0, 0, 0, 0x08)
    hb_pam = _dw(hw, 0, 0, 0, 0x5C)
    print("== Host bridge  00:00.0 ==")
    print("  id    %08X  vendor=%04X device=%04X  (%s)"
          % (hb_id, hb_id & 0xFFFF, (hb_id >> 16) & 0xFFFF,
             "Intel i440FX host/DRAM bridge" if hb_id == 0x12378086 else "unknown"))
    print("  class %08X  code=%06X rev=%02X  cmd=%04X status=%04X"
          % (hb_cls, (hb_cls >> 8) & 0xFFFFFF, hb_cls & 0xFF,
             hb_cmd & 0xFFFF, (hb_cmd >> 16) & 0xFFFF))
    print("  PAM3-6 (0x5C)=%08X  -> BIOS/ROM shadow attributes" % hb_pam)

    # --- 00:01.3 PIIX4 ACPI / PM ---
    pm_id = _dw(hw, 0, 1, 3, 0x00)
    pm_cls = _dw(hw, 0, 1, 3, 0x08)
    pm_irq = _dw(hw, 0, 1, 3, 0x3C)
    pmba = _dw(hw, 0, 1, 3, 0x40)
    smba = _dw(hw, 0, 1, 3, 0x90)
    pmregmisc = _dw(hw, 0, 1, 3, 0x80)
    print("== ACPI / PM    00:01.3 ==")
    print("  id    %08X  vendor=%04X device=%04X  (%s)"
          % (pm_id, pm_id & 0xFFFF, (pm_id >> 16) & 0xFFFF,
             "Intel PIIX4 ACPI/power mgmt" if pm_id == 0x71138086 else "unknown"))
    print("  class %08X  code=%06X rev=%02X  IRQ=%d pin=INT%s"
          % (pm_cls, (pm_cls >> 8) & 0xFFFFFF, pm_cls & 0xFF,
             pm_irq & 0xFF, chr(ord('A') + ((pm_irq >> 8) & 0xFF) - 1) if (pm_irq >> 8) & 0xFF else "-"))
    print("  PMBA  (0x40)=%08X  -> PM/ACPI I/O base 0x%04X (PM timer @ 0x%04X), PMIOSE=%d"
          % (pmba, pmba & 0xFFC0, (pmba & 0xFFC0) + 0x08, pmregmisc & 1))
    print("  SMBA  (0x90)=%08X  -> SMBus host I/O base 0x%04X" % (smba, smba & 0xFFF0))


if __name__ == "__main__":
    main()
