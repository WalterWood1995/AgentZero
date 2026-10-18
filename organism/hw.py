#!/usr/bin/env python3
# hw.py - the AgentZero "organism": a hardware-access library. This is the ONLY way
# an Agent touches the metal - the bare-metal kernel's ring-0 instruction set over
# UDP (port 50000). Read primitives are safe; writes are gated. An Agent uses this
# to PROBE a device, then reasons about it and writes down what it learned.
#
# CLI (for Agents to call from a shell):
#   python hw.py [ip] cpuid|rtc
#   python hw.py [ip] pci-scan
#   python hw.py [ip] pci  <bus> <dev> <fn> [off]        # one config dword (hex)
#   python hw.py [ip] cfg  <bus> <dev> <fn>              # full 256-byte config space
#   python hw.py [ip] mem  <addr> <len>                  # read physical memory (hex)
#   python hw.py [ip] in   <port>                        # inb from an I/O port
# IP defaults to 127.0.0.1 (a QEMU-hosted kernel); pass the Asus IP for real metal.
import socket
import sys
import time

PORT = 50000


class HW:
    def __init__(self, ip="127.0.0.1", port=PORT, timeout=2.5):
        self.ip, self.port, self.timeout = ip, port, timeout
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def _reply(self, cmd, tries=5):
        """Send a command, return the kernel's reply as text (lossy link -> retry)."""
        for _ in range(tries):
            self.s.setblocking(False)                    # drain stale/late replies
            try:
                while True:
                    self.s.recvfrom(4096)
            except OSError:
                pass
            self.s.setblocking(True)
            self.s.settimeout(self.timeout)
            try:
                self.s.sendto(cmd.encode(), (self.ip, self.port))
                data, _ = self.s.recvfrom(4096)
                return data.decode("latin1")
            except socket.timeout:
                continue
        return None

    def result(self, cmd, tries=5):
        """The RESULT of a command = the last non-empty line (the kernel echoes each
        command as 8-bit binary first, then prints the result)."""
        r = self._reply(cmd, tries)
        if r is None:
            return None
        lines = [ln.strip() for ln in r.replace("\r", "\n").split("\n") if ln.strip()]
        return lines[-1] if lines else ""

    # ---- read primitives (safe) ----
    def cpuid_vendor(self):
        return self.result("C")

    def cpuid_leaf1(self):
        v = self.result("F")
        return int(v, 16) if v else None

    def rtc(self):
        return self.result("T")

    def inb(self, port):
        r = self.result("I%04X" % port)
        if r and "=" in r:
            try:
                return int(r.split("=")[-1], 16)
            except ValueError:
                return None
        return None

    def mem(self, addr, length):
        """Read `length` (<=255) bytes of physical memory -> bytes."""
        out = bytearray()
        while length > 0:
            n = min(length, 64)
            r = self.result("M%08X%02X" % (addr, n))
            if not r:
                break
            try:
                out += bytes(int(x, 16) for x in r.split())
            except ValueError:
                break
            addr += n
            length -= n
        return bytes(out)

    def pci(self, bus, dev, fn, off=0):
        """One PCI config-space dword (mechanism 1) -> int, or None."""
        r = self.result("P%02X%02X%01X%02X" % (bus, dev, fn, off))
        try:
            return int(r, 16) if r else None
        except ValueError:
            return None

    def pci_config(self, bus, dev, fn, nbytes=256):
        """Full config space as a list of dwords (nbytes/4 of them)."""
        return [self.pci(bus, dev, fn, off) for off in range(0, nbytes, 4)]

    def pci_scan(self, buses=range(0, 6)):
        """Enumerate PCI devices: [{bus,dev,fn,vendor,device,classcode}]."""
        found = []
        for bus in buses:
            for dev in range(32):
                v0 = self.pci(bus, dev, 0, 0)
                if not v0 or (v0 & 0xFFFF) == 0xFFFF:
                    continue
                htype = self.pci(bus, dev, 0, 0x0C)
                multi = bool(htype and (htype >> 16) & 0x80)
                for fn in range(8 if multi else 1):
                    vid = self.pci(bus, dev, fn, 0)
                    if not vid or (vid & 0xFFFF) == 0xFFFF:
                        continue
                    cls = self.pci(bus, dev, fn, 0x08)
                    found.append({"bus": bus, "dev": dev, "fn": fn,
                                  "vendor": vid & 0xFFFF, "device": (vid >> 16) & 0xFFFF,
                                  "classcode": (cls >> 8) & 0xFFFFFF if cls else None})
        return found


def _main():
    a = sys.argv[1:]
    ip = "127.0.0.1"
    if a and a[0].count(".") == 3:
        ip = a.pop(0)
    hw = HW(ip)
    if not a:
        print(__doc__); return
    op = a[0]
    if op == "cpuid":
        print("vendor:", hw.cpuid_vendor(), " leaf1_eax: 0x%08X" % (hw.cpuid_leaf1() or 0))
    elif op == "rtc":
        print("rtc:", hw.rtc())
    elif op == "pci-scan":
        for d in hw.pci_scan():
            print("%02x:%02x.%d  %04x:%04x  class %06x"
                  % (d["bus"], d["dev"], d["fn"], d["vendor"], d["device"], d["classcode"] or 0))
    elif op == "pci":
        b, dv, fn = int(a[1], 16), int(a[2], 16), int(a[3], 16)
        off = int(a[4], 16) if len(a) > 4 else 0
        print("0x%08X" % (hw.pci(b, dv, fn, off) or 0))
    elif op == "cfg":
        b, dv, fn = int(a[1], 16), int(a[2], 16), int(a[3], 16)
        dw = hw.pci_config(b, dv, fn)
        for i, v in enumerate(dw):
            print("%02X: %08X" % (i * 4, v or 0))
    elif op == "mem":
        print(hw.mem(int(a[1], 16), int(a[2])).hex(" "))
    elif op == "in":
        print("0x%02X" % (hw.inb(int(a[1], 16)) or 0))
    else:
        print("unknown op", op)


if __name__ == "__main__":
    _main()
