#!/usr/bin/env python3
# face.py - render a photo to an 80x50 ASCII portrait and draw it on the
# AgentZero machine's green screen, making the old PC the agent's face.
#
# Draws with the kernel's block command for speed/reliability on a lossy link:
#   X              -> clear screen + display mode
#   B<2hex row>\n<line>\n<line>...  -> write many rows in one packet (col 0)
# Fire-and-forget with redundancy (the kernel acks nothing for display commands,
# and B is idempotent), so no per-line round trip and lost packets are covered
# by resending each block a few times.
#
# Usage: python3 face.py [ip] [image] [speech line ...]
#   default ip = 127.0.0.1 (QEMU hostfwd); use 192.168.178.114 for the Asus.
import os
import socket
import sys
import time
import ascii_art

PORT = 50000
W = 40                    # portrait width (kept small so it isn't squashed)
PAD = (80 - W) // 2       # left padding to centre it
CHUNK = 6                 # face rows per packet (~360B - small enough for real HW)
REPEAT = 5                # resend each packet this many times (loss cover)
GAP = 0.04                # seconds between sends


def blast(sock, ip, payload):
    for _ in range(REPEAT):
        sock.sendto(payload, (ip, PORT))
        time.sleep(GAP)


def main():
    args = sys.argv[1:]
    ip = "127.0.0.1"
    if args and args[0].count(".") == 3:
        ip = args.pop(0)
    img = "einstein.jpg"
    if args and args[0].lower().endswith((".jpg", ".jpeg", ".png", ".bmp")) and os.path.exists(args[0]):
        img = args.pop(0)
    speech = args

    lines = ascii_art.render(img, W, rows=46)       # leave room for a speech line
    disp = [" " * PAD + ln for ln in lines]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    blast(s, ip, b"X")                              # clear
    row = 0
    while row < len(disp):
        block = disp[row:row + CHUNK]
        payload = ("B%02X\n" % row).encode() + "\n".join(block).encode("latin1")
        blast(s, ip, payload)
        row += CHUNK
    srow = len(disp) + 1
    for i, line in enumerate(speech):
        blast(s, ip, ("B%02X\n  > %s" % (srow + i, line)).encode("latin1"))

    print("drew %s (%d rows) on %s" % (img, len(disp), ip))


if __name__ == "__main__":
    main()
