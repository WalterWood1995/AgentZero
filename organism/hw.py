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
#   python hw.py [ip] out   <port> <val>                 # GATED outb (confirm byte)
#   python hw.py [ip] write <addr> <dword>               # GATED mem/MMIO dword write
# IP defaults to 127.0.0.1 (a QEMU-hosted kernel); pass the Asus IP for real metal.
#
# WRITES ARE GATED. The kernel refuses a write whose command lacks the trailing
# '!' confirm byte, so hw.py never writes by accident. An Agent must not call these
# ad hoc: it proposes a write as a reviewed skill (the exact writes + why they are
# safe), which is armed before it runs (see GENOME.md "gated write skills"). The
# SATA/AHCI controller is off-limits for writes.
import os
import socket
import sys
import time

PORT = 50000


class HW:
    def __init__(self, ip="127.0.0.1", port=None, timeout=2.5):
        # AGENTZERO_PORT lets a second kernel instance (e.g. a test QEMU on a
        # different host UDP forward) be reached without editing call sites.
        if port is None:
            port = int(os.environ.get("AGENTZERO_PORT", PORT))
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

    # ---- write primitives (GATED: the kernel needs the trailing '!' confirm
    # byte, so a write only happens when we deliberately send it). These are the
    # organism's only way to change hardware state; use them only from a reviewed,
    # armed write-skill, never ad hoc. ----
    def outb(self, port, val, confirm=True):
        """GATED outb: O<4hex port><2hex val>!  -> 'write ok' or 'write aborted'.
        confirm=False deliberately omits '!' so the kernel refuses (gate self-test)."""
        cmd = "O%04X%02X" % (port & 0xFFFF, val & 0xFF)
        if confirm:
            cmd += "!"
        return self.result(cmd)

    def write32(self, addr, dword, confirm=True):
        """GATED dword write to linear/physical memory or MMIO:
        W<8hex addr><8hex dword>!  -> 'write ok' or 'write aborted'.
        Reaches plain RAM and memory-mapped device registers (e.g. e1000 BAR0).
        confirm=False omits '!' so the kernel refuses (gate self-test)."""
        cmd = "W%08X%08X" % (addr & 0xFFFFFFFF, dword & 0xFFFFFFFF)
        if confirm:
            cmd += "!"
        return self.result(cmd)

    # ---- compute primitives: the old PC's CPU does real work on demand ----
    def _raw(self, payload, tries=5):
        """Send raw bytes, return the raw reply datagram (for L/E, whose replies are
        binary and carry no command echo). Drains stale replies, retries on loss."""
        for _ in range(tries):
            self.s.setblocking(False)
            try:
                while True:
                    self.s.recvfrom(4096)
            except OSError:
                pass
            self.s.setblocking(True)
            self.s.settimeout(self.timeout)
            try:
                self.s.sendto(payload, (self.ip, self.port))
                data, _ = self.s.recvfrom(4096)
                return data
            except socket.timeout:
                continue
        return None

    def alu(self, op, a, b=0):
        """Ask the machine's CPU to compute a math problem: A<op><8hex a><8hex b>.
        op in '+-*' / 'g'(gcd) / 's'(sum 1..a) / 'f'(factorial a). Returns an int."""
        r = self.result("A%s%08X%08X" % (op, a & 0xFFFFFFFF, b & 0xFFFFFFFF))
        try:
            return int(r, 16) if r else None
        except ValueError:
            return None

    def load(self, addr, data, chunk=512, verify=True):
        """Bulk-load bytes into the old PC's compute scratch RAM via the L command
        (gated to [0x100000,0x180000)). Small chunks ride the lossy real-metal link.
        On real hardware the 1-byte 'L' ack is frequently dropped even though the
        write itself lands (the gated rep-movsb is reliable), so we also accept a
        readback match as success rather than failing the whole load on a lost ack."""
        off = 0
        while off < len(data):
            piece = data[off:off + chunk]
            hdr = ("L%08X" % (addr + off)).encode()
            ok = False
            for _ in range(4):
                r = self._raw(hdr + piece, tries=1)
                if r and r[:1] == b"L":
                    ok = True
                    break
                if verify:                       # ack lost? trust a readback match
                    n = min(len(piece), 32)
                    if self.mem(addr + off, n) == piece[:n]:
                        ok = True
                        break
            if not ok:
                return False
            off += len(piece)
        return True

    def fourier(self, t):
        """Evaluate the preloaded Fourier epicycle chain at time step t on the old
        PC's CPU: E<4hex t> -> list of (x,y) int points (centre .. pen tip)."""
        r = self._raw(("E%04X" % (t & 0xFFFF)).encode())
        if not r:
            return None
        pts = []
        for i in range(0, len(r) - 1, 4):
            x = int.from_bytes(r[i:i + 2], "little", signed=True)
            y = int.from_bytes(r[i + 2:i + 4], "little", signed=True)
            pts.append((x, y))
        return pts

    # ---- display: show text on the old PC's screen (fire-and-forget commands) ----
    def _disp(self, payload, repeat=4):
        """Display commands (X/D/S/B) get no reply; the lossy link drops packets, so
        send each a few times. They are idempotent (overwrite the same cells)."""
        for _ in range(repeat):
            try:
                self.s.sendto(payload if isinstance(payload, bytes) else payload.encode(),
                              (self.ip, self.port))
            except OSError:
                pass
            time.sleep(0.02)

    def disp_clear(self):
        self._disp("X")

    def disp_at(self, row, col, text):
        """Write text at (row, col) on the screen (S command). Idempotent."""
        self._disp("S%02X%02X%s" % (row & 0x7F, col & 0x7F, text))

    def disp_lines(self, start_row, lines):
        """Write several lines starting at start_row, one per row (B block command)."""
        body = "\n".join(lines)
        self._disp(("B%02X\n" % (start_row & 0x7F)).encode() + body.encode())

    def mem32(self, addr):
        """Read back a plain-RAM dword (little-endian) to verify a write landed."""
        b = self.mem(addr, 4)
        return int.from_bytes(b, "little") if b and len(b) == 4 else None

    # ---- autonomy: screenshot (read the old PC's framebuffer) + reboot ----
    def geom(self):
        """Query the graphics framebuffer geometry (Q command) -> (w,h,pitch,bpp)."""
        r = self._raw(b"Q")
        if not r or len(r) < 16:
            return None
        import struct
        return struct.unpack("<IIII", r[:16])

    def fb_read(self, off, length):
        """Read `length` (<=1400) bytes of the framebuffer at byte `off` (Y command)."""
        r = self._raw(("Y%08X%04X" % (off, length & 0xFFFF)).encode())
        return r if r else b""

    def screenshot(self, path=None, w=None, h=None, pitch=None, y0=0, y1=None, chunk=1400):
        """Read the old PC's VBE framebuffer back over UDP and save it as a PNG.
        y0..y1 limit the rows (for a fast partial grab, e.g. a status bar)."""
        from PIL import Image
        import numpy as np
        g = self.geom()
        if g and not (w and h and pitch):
            w, h, pitch, _ = g
        w = w or 1024; h = h or 768; pitch = pitch or w * 4
        if y1 is None:
            y1 = h
        rows = []
        for y in range(y0, y1):
            base = y * pitch
            line = bytearray()
            x = 0
            while x < w * 4:
                n = min(chunk, w * 4 - x)
                d = self.fb_read(base + x, n)
                if not d:
                    d = b"\x00" * n          # ride out a dropped reply
                line += d[:n]
                x += n
            rows.append(bytes(line[:w * 4]))
        buf = b"".join(rows)
        arr = np.frombuffer(buf, np.uint8).reshape(len(rows), w, 4)
        rgb = arr[:, :, [2, 1, 0]]           # BGRX -> RGB
        img = Image.fromarray(rgb, "RGB")
        if path:
            img.save(path)
        return img

    def reboot(self):
        """Reboot the old PC (K! = 8042 CPU reset); it re-PXE-boots the latest image.
        Fire-and-forget: the machine resets before any reply."""
        for _ in range(4):
            try:
                self.s.sendto(b"K!", (self.ip, self.port))
            except OSError:
                pass
            time.sleep(0.03)

    def mmio_lowbyte(self, addr):
        """Read back an MMIO register's low byte. The `mem` reader returns each
        device register's low byte replicated across the 4 lanes, so only the low
        byte is recoverable this way - enough to verify an MMIO write took."""
        b = self.mem(addr, 4)
        return b[0] if b else None

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
    elif op == "out":                                    # GATED outb
        print("outb 0x%04X <- 0x%02X : %s"
              % (int(a[1], 16), int(a[2], 16), hw.outb(int(a[1], 16), int(a[2], 16))))
    elif op == "write":                                  # GATED mem/MMIO dword write
        print("write [0x%08X] <- 0x%08X : %s"
              % (int(a[1], 16), int(a[2], 16), hw.write32(int(a[1], 16), int(a[2], 16))))
    else:
        print("unknown op", op)


if __name__ == "__main__":
    _main()
