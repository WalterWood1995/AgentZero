#!/usr/bin/env python3
# agent_repl.py - the Agent's client for the bare-metal ring-0 REPL.
# Boots disk.img in QEMU, talks to the kernel over the COM1 serial channel,
# sends commands and returns the kernel's replies. This is the host-side half
# of the Agent<->bare-metal instruction set; on real hardware the same bytes
# go over a physical COM1 or a network bridge instead of QEMU stdio.
#
# Usage: python3 agent_repl.py C F I0064 T M00007DFC04 P0000000 "O0080AB!" ?
#        (no args -> runs a default demo batch exercising every instruction)
#
# Instruction set (milestone 3, 32-bit protected mode):
#   C                       CPUID leaf 0 vendor string
#   F                       CPUID leaf 1 EAX (family/model/stepping)
#   I<4hex>                 inb from an I/O port -> "=XX"
#   T                       RTC time from CMOS, HH:MM:SS (BCD)
#   M<8hex addr><2hex len>  read <len> bytes of linear memory, hex dump
#   P<2hex bus><2hex dev><1hex func><2hex off>
#                           PCI config dword via mechanism 1 (0xCF8/0xCFC)
#   O<4hex port><2hex val>! GATED outb - trailing '!' confirm byte required
#   ?                       list commands

import os
import subprocess
import sys
import threading
import time

QEMU = os.environ.get("QEMU", "qemu-system-i386")  # full path, or set the QEMU env var
DISK = "disk.img"


def run(commands, boot_wait=5.0, step=0.7):
    # boot_wait covers the ~4.3s Matrix rain intro so commands land after the
    # REPL is reading serial (the UART has no FIFO here, so bytes sent during
    # the intro would be overwritten). A human can press a key to skip the rain.
    p = subprocess.Popen(
        [QEMU, "-drive", "format=raw,file=%s" % DISK,
         "-serial", "stdio", "-display", "none", "-no-reboot"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, bufsize=0)
    out = bytearray()

    def reader():
        while True:
            b = p.stdout.read(1)
            if not b:
                break
            out.extend(b)

    threading.Thread(target=reader, daemon=True).start()
    time.sleep(boot_wait)                      # boot + UART init
    for cmd in commands:
        data = cmd.encode() if isinstance(cmd, str) else cmd
        # QEMU's Windows -serial stdio runs stdin in text mode and swallows CR,
        # so terminate each line with LF; the kernel accepts CR or LF.
        p.stdin.write(data + b"\n")
        p.stdin.flush()
        time.sleep(step)
    time.sleep(0.4)
    p.terminate()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill()
    return bytes(out).decode("latin1")


if __name__ == "__main__":
    cmds = sys.argv[1:] or [
        "C",            # CPUID vendor
        "F",            # CPUID leaf 1
        "I0064",        # inb keyboard status port
        "T",            # RTC time
        "M00007DFC04",  # memory: last 4 bytes of the boot sector -> 00 00 55 AA
        "P0000000",     # PCI 00:00.0 off 0  -> host bridge vendor/device 12378086
        "P0000008",     # PCI 00:00.0 off 8  -> class code 06000002 (host bridge)
        "O0080AB!",     # gated write: outb 0xAB -> port 0x80 (confirmed)
        "O0080ABX",     # gated write without '!' -> aborted
        "?",            # help
    ]
    sys.stdout.write(run(cmds))
