#!/usr/bin/env python3
# udp_agent.py - the Agent's client for the bare-metal kernel's NETWORK command
# channel (PXE UDP API). Sends ring-0 hardware commands to the kernel over UDP
# and prints the replies. The real machine (Asus K50IJ) has no serial port, so
# this is how the Agent drives it once it is PXE-booted.
#
# Usage: python3 udp_agent.py [ip] [cmd ...]
#   default ip   = 192.168.178.114 (the Asus's DHCP address)
#   default cmds = a demo batch exercising the instruction set
# The kernel listens on UDP port 50000 and replies to the sender.

import socket
import sys

PORT = 50000
ip = "192.168.178.114"
args = sys.argv[1:]
if args and args[0].count(".") == 3:
    ip = args.pop(0)
cmds = args or ["C", "F", "I0064", "T", "P0000000", "P0000008", "M00007DFC04", "?"]

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for c in cmds:
    # drain any stale/late reply so replies can't shift onto the next command
    s.setblocking(False)
    try:
        while True:
            s.recvfrom(4096)
    except (BlockingIOError, OSError):
        pass
    s.setblocking(True)
    s.settimeout(4.0)
    reply = None
    for _ in range(3):                       # first round-trip can be slow (ARP)
        try:
            s.sendto(c.encode(), (ip, PORT))
            reply, _ = s.recvfrom(4096)
            break
        except socket.timeout:
            continue
    if reply is not None:
        sys.stdout.write("agent> %s%s\n" % (c, reply.decode("latin1")))
    else:
        sys.stdout.write("agent> %s -> (timeout, no reply from %s)\n" % (c, ip))
