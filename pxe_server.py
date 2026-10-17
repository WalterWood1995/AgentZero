#!/usr/bin/env python3
# pxe_server.py - minimal proxyDHCP + TFTP server for booting the AgentZero
# over the network. It does NOT hand out IP addresses (the home router's DHCP
# keeps doing that); it only answers PXE clients with "fetch pxe.img from me over
# TFTP". Run it on the dev PC; point the old Asus at Network boot (F8).
#
#   proxyDHCP : UDP 67 (and PXE boot-server 4011) - tells the client the boot
#               server + filename, with yiaddr=0 so it never assigns an IP.
#   TFTP      : UDP 69 - serves pxe.img (block-by-block, blksize/tsize OACK).
#
# Privileged ports (67/69/4011) -> must run elevated, and Windows Firewall must
# allow inbound UDP. Use run_pxe_server.ps1 which adds the rules and elevates.
#
# Usage: python3 pxe_server.py [server_ip]   (default 192.168.178.113)

import os
import socket
import struct
import sys
import threading
import time

SERVER_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.178.113"
HERE = os.path.dirname(os.path.abspath(__file__))
TFTP_DIR = HERE                      # serve pxe.img straight from the build dir
BOOTFILE = "pxe.img"
LOG = os.path.join(os.environ.get("TEMP", "."), "jev_pxe_server.log")


def log(msg):
    line = "%s  %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def ip_bytes(ip):
    return socket.inet_aton(ip)


def parse_opts(data):
    opts = {}
    i = 0
    while i < len(data):
        code = data[i]
        if code == 255:
            break
        if code == 0:
            i += 1
            continue
        ln = data[i + 1]
        opts[code] = data[i + 2:i + 2 + ln]
        i += 2 + ln
    return opts


def build_dhcp_reply(req, msgtype):
    # req is the raw request packet; reuse xid/chaddr/giaddr/flags.
    xid = req[4:8]
    flags = req[10:12]
    giaddr = req[24:28]
    chaddr = req[28:44]

    pkt = bytearray(240)
    pkt[0] = 2                       # BOOTREPLY
    pkt[1] = 1                       # htype ethernet
    pkt[2] = 6                       # hlen
    pkt[3] = 0
    pkt[4:8] = xid
    pkt[8:10] = b"\x00\x00"          # secs
    pkt[10:12] = flags
    # ciaddr / yiaddr = 0  (proxyDHCP never assigns an address)
    pkt[20:24] = ip_bytes(SERVER_IP)  # siaddr = next server (TFTP)
    pkt[24:28] = giaddr
    pkt[28:44] = chaddr
    # sname(64) zero; file(128) = bootfile
    fname = BOOTFILE.encode()
    pkt[108:108 + len(fname)] = fname
    pkt[236:240] = b"\x63\x82\x53\x63"  # magic cookie

    opts = bytearray()
    opts += bytes([53, 1, msgtype])                      # DHCP message type
    opts += bytes([54, 4]) + ip_bytes(SERVER_IP)         # server identifier
    vc = b"PXEClient"
    opts += bytes([60, len(vc)]) + vc                    # vendor class
    opts += bytes([66, len(SERVER_IP)]) + SERVER_IP.encode()   # TFTP server name
    bf = BOOTFILE.encode()
    opts += bytes([67, len(bf)]) + bf                    # bootfile name
    # PXE vendor options: PXE_DISCOVERY_CONTROL = use bootfile directly
    opts += bytes([43, 4, 6, 1, 0x08, 0xFF])
    opts += bytes([255])                                 # end
    return bytes(pkt) + bytes(opts)


def dhcp_listener(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        s.bind(("0.0.0.0", port))
    except OSError as e:
        log("DHCP bind :%d failed: %s" % (port, e))
        return
    log("proxyDHCP listening on :%d (server %s, bootfile %s)" % (port, SERVER_IP, BOOTFILE))
    while True:
        try:
            data, addr = s.recvfrom(4096)
        except OSError:
            continue
        if len(data) < 240 or data[0] != 1 or data[236:240] != b"\x63\x82\x53\x63":
            continue
        opts = parse_opts(data[240:])
        vendor = opts.get(60, b"")
        if not vendor.startswith(b"PXEClient"):
            continue                 # only answer PXE clients, ignore normal DHCP
        mt = opts.get(53, b"\x00")[0]
        if mt == 1:                  # DISCOVER
            reply = build_dhcp_reply(data, 2)   # proxyDHCP OFFER
            kind = "OFFER"
        elif mt in (3, 8):           # REQUEST / INFORM
            reply = build_dhcp_reply(data, 5)   # ACK
            kind = "ACK"
        else:
            continue
        mac = ":".join("%02x" % b for b in data[28:34])
        log("PXE %s from %s (:%d) -> %s bootfile=%s" % (
            {1: "DISCOVER", 3: "REQUEST", 8: "INFORM"}.get(mt, mt), mac, port, kind, BOOTFILE))
        s.sendto(reply, ("255.255.255.255", 68))
        if addr[0] not in ("0.0.0.0",):
            try:
                s.sendto(reply, (addr[0], 68))
            except OSError:
                pass


def tftp_serve(cli, fname_raw, req_opts):
    # We only ever serve ONE file. Some PXE ROMs append junk bytes to the
    # requested name, so don't trust it - always send BOOTFILE.
    log("TFTP RRQ raw=%r -> serving %s" % (fname_raw, BOOTFILE))
    path = os.path.join(TFTP_DIR, BOOTFILE)
    if not os.path.isfile(path):
        err = struct.pack("!HH", 5, 1) + b"File not found\x00"
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(err, cli)
        log("TFTP %s MISSING on server!" % BOOTFILE)
        return
    data = open(path, "rb").read()
    blksize = 512
    oack = {}
    if b"blksize" in req_opts:
        try:
            blksize = max(8, min(1432, int(req_opts[b"blksize"])))
            oack["blksize"] = str(blksize)
        except ValueError:
            pass
    if b"tsize" in req_opts:
        oack["tsize"] = str(len(data))

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 0))
    s.settimeout(3.0)
    log("TFTP send %s (%d bytes, blksize=%d) to %s:%d" % (BOOTFILE, len(data), blksize, cli[0], cli[1]))

    def send_wait(pkt, expect_block):
        for _ in range(5):
            s.sendto(pkt, cli)
            try:
                ack, _ = s.recvfrom(1024)
            except socket.timeout:
                continue
            if len(ack) >= 4 and struct.unpack("!H", ack[:2])[0] == 4 \
                    and struct.unpack("!H", ack[2:4])[0] == (expect_block & 0xFFFF):
                return True
        return False

    if oack:
        pkt = struct.pack("!H", 6)
        for k, v in oack.items():
            pkt += k.encode() + b"\x00" + v.encode() + b"\x00"
        if not send_wait(pkt, 0):     # client ACKs block 0 for OACK
            log("TFTP OACK not acked, aborting")
            s.close()
            return

    block = 1
    off = 0
    while True:
        chunk = data[off:off + blksize]
        pkt = struct.pack("!HH", 3, block & 0xFFFF) + chunk
        if not send_wait(pkt, block):
            log("TFTP block %d not acked, aborting" % block)
            break
        off += len(chunk)
        block += 1
        if len(chunk) < blksize:
            log("TFTP transfer complete (%d bytes)" % off)
            break
    s.close()


def tftp_listener():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", 69))
    except OSError as e:
        log("TFTP bind :69 failed: %s" % e)
        return
    log("TFTP listening on :69 (dir %s)" % TFTP_DIR)
    while True:
        try:
            data, cli = s.recvfrom(4096)
        except OSError:
            continue
        if len(data) < 4:
            continue
        op = struct.unpack("!H", data[:2])[0]
        if op != 1:                  # only RRQ
            continue
        parts = data[2:].split(b"\x00")
        fname_raw = parts[0]
        req_opts = {}
        rest = parts[2:]
        for i in range(0, len(rest) - 1, 2):
            req_opts[rest[i].lower()] = rest[i + 1]
        threading.Thread(target=tftp_serve, args=(cli, fname_raw, req_opts), daemon=True).start()


if __name__ == "__main__":
    try:
        open(LOG, "w").close()
    except OSError:
        pass
    log("JEV PXE server starting. Serving %s from %s" % (BOOTFILE, TFTP_DIR))
    log("pxe.img present: %s" % os.path.isfile(os.path.join(TFTP_DIR, BOOTFILE)))
    threading.Thread(target=dhcp_listener, args=(67,), daemon=True).start()
    threading.Thread(target=dhcp_listener, args=(4011,), daemon=True).start()
    threading.Thread(target=tftp_listener, daemon=True).start()
    log("ready - now F8-boot the old Asus and pick Network. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log("stopped.")
