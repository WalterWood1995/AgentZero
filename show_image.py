#!/usr/bin/env python3
# show_image.py - stream a photo to the AgentZero bare-metal kernel's VBE linear
# framebuffer over UDP, so an OS-less laptop displays a full-screen image.
#
# The dev PC does all the heavy lifting (decode / scale / BGRX conversion); the
# kernel just copies raw pixel bytes into the framebuffer. UDP protocol (:50000):
#   Q                               -> reply 16 bytes: <w h pitch bpp> (LE)
#   V                               -> switch the live display into graphics mode
#                                      (reply 1 byte: 1 = ready, 0 = no VBE)
#   G<8 hex LFB byte offset><bytes> -> write those bytes at that framebuffer offset
#   U                               -> back to text mode + redraw the face
#
# In the default face/chat kernel these switch the screen live (face <-> image).
# Used standalone or imported by agent_chat.py (for `web <domain>` screenshots).
#
# Usage:
#   python show_image.py <image> [old-pc-ip] [--fit|--cover|--stretch]
#          [--enter] [--exit] [--passes N] [--chunk PIXELS] [--delay SEC]
import os, socket, struct, sys, time

try:
    from PIL import Image
    import numpy as np
except ImportError as _e:                           # let importers degrade gracefully
    if __name__ == "__main__":
        sys.exit("needs Pillow + numpy:  pip install pillow numpy")
    raise

PORT       = int(os.environ.get("AGENTZERO_PORT", "50000"))  # override for test QEMU
DEF_IP     = "192.168.178.114"      # old Asus (see memory)
DEF_W, DEF_H, DEF_PITCH, DEF_BPP = 1024, 768, 1024 * 4, 32


def _sock():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.5)
    return s


def query_geometry(sock, ip):
    """Ask the kernel for its real framebuffer geometry; fall back to defaults."""
    try:
        sock.sendto(b"Q\0", (ip, PORT))     # never a 1-byte datagram: the Asus PXE ROM drops those
        for _ in range(3):
            try:
                data, _ = sock.recvfrom(64)
            except (ConnectionResetError, OSError):
                continue
            if len(data) >= 16:
                w, h, pitch, bpp = struct.unpack("<4I", data[:16])
                if 0 < w <= 4096 and 0 < h <= 4096 and pitch >= w * 4:
                    return w, h, pitch, bpp
    except (ConnectionResetError, OSError, socket.timeout):
        pass
    return DEF_W, DEF_H, DEF_PITCH, DEF_BPP


def enter_graphics(sock, ip, tries=8):
    """Switch to graphics mode. Sent several times (gfx_enter is idempotent) in case a
    packet is lost - if even one V is lost the kernel would ignore every following G.
    Padded to 2 bytes: the Asus PXE ROM never delivers a 1-byte UDP payload, which is
    what made "V" look lossy on real metal. Collect the ack byte if any."""
    acked = None
    for _ in range(tries):
        try:
            sock.sendto(b"V\0", (ip, PORT))
            data, _ = sock.recvfrom(16)
            if data:
                acked = data[0]
        except (ConnectionResetError, OSError, socket.timeout):
            pass
        time.sleep(0.08)
    return acked                # 1 = graphics engaged, 0 = no VBE, None = no ack (assume ok)


def exit_graphics(sock, ip):
    """Send U (back to text mode + face). Fire-and-forget, with redundancy."""
    for _ in range(3):
        try:
            sock.sendto(b"U\0", (ip, PORT))     # padded: 1-byte datagrams never arrive
        except OSError:
            pass
        time.sleep(0.05)


def fit_image(src, w, h, mode="cover"):
    """src is a path or a PIL Image. Returns an (h, w, 4) BGRX uint8 array."""
    img = src if isinstance(src, Image.Image) else Image.open(src)
    img = img.convert("RGB")
    if mode == "stretch":
        img = img.resize((w, h), Image.LANCZOS)
    elif mode == "fit":                              # letterbox: whole image, black bars
        img.thumbnail((w, h), Image.LANCZOS)
        canvas = Image.new("RGB", (w, h), (0, 0, 0))
        canvas.paste(img, ((w - img.width) // 2, (h - img.height) // 2))
        img = canvas
    else:                                            # cover: fill screen, center-crop
        src_ar, dst_ar = img.width / img.height, w / h
        if src_ar > dst_ar:
            nw = int(img.height * dst_ar)
            img = img.crop(((img.width - nw) // 2, 0, (img.width - nw) // 2 + nw, img.height))
        else:
            nh = int(img.width / dst_ar)
            img = img.crop((0, (img.height - nh) // 2, img.width, (img.height - nh) // 2 + nh))
        img = img.resize((w, h), Image.LANCZOS)
    rgb = np.asarray(img, dtype=np.uint8)            # (h, w, 3)
    bgrx = np.zeros((h, w, 4), dtype=np.uint8)
    bgrx[..., 0] = rgb[..., 2]                        # B
    bgrx[..., 1] = rgb[..., 1]                        # G
    bgrx[..., 2] = rgb[..., 0]                        # R
    return bgrx                                       # X = 0


def stream_bgrx(sock, ip, bgrx, pitch, passes=2, chunkpix=180, delay=0.0006):
    """Send a BGRX frame to the framebuffer, scanline by scanline (never spanning
    the pitch gap). Several idempotent passes ride out dropped packets."""
    h, w = bgrx.shape[0], bgrx.shape[1]
    maxpix = min(chunkpix, 360)                       # keep each packet <= 1472 bytes
    npkt = 0
    for _ in range(passes):
        for y in range(h):
            row = bgrx[y].tobytes()
            base = y * pitch
            x = 0
            while x < w:
                n = min(maxpix, w - x)
                pkt = b"G" + ("%08X" % (base + x * 4)).encode() + row[x * 4: x * 4 + n * 4]
                try:
                    sock.sendto(pkt, (ip, PORT))
                except (ConnectionResetError, OSError):
                    pass
                npkt += 1
                if delay:
                    time.sleep(delay)
                x += n
    return npkt


def stream_rle(sock, ip, bgrx, pitch, passes=2, delay=0.0004, maxruns=240):
    """Run-length-encode the frame and send it. A flat page (text / reader view) is
    mostly long runs of one colour, so this is far fewer packets than raw G pixels.
    Packet: 'Z' + 8hex start LFB offset + runs of count(2 LE) + pixel(4 LE BGRX).
    Runs are sequential within a scanline (never crossing the pitch gap)."""
    h, w = bgrx.shape[0], bgrx.shape[1]
    px = np.ascontiguousarray(bgrx).view(np.uint32).reshape(h, w)
    packets = []
    for y in range(h):
        row = px[y].tolist()
        base = y * pitch
        runs = []                                  # flat [count, pixel, count, pixel, ...]
        x = 0
        while x < w:
            v = row[x]; j = x + 1
            while j < w and row[j] == v:
                j += 1
            c = j - x
            while c > 65535:
                runs += [65535, v]; c -= 65535
            runs += [c, v]
            x = j
        nr = len(runs) // 2
        idx, cumx = 0, 0
        while idx < nr:
            sx = cumx
            take = min(maxruns, nr - idx)
            data = bytearray()
            for k in range(take):
                c = runs[(idx + k) * 2]; v = runs[(idx + k) * 2 + 1]
                data += struct.pack("<HI", c, v & 0xFFFFFFFF)
                cumx += c
            idx += take
            packets.append(b"Z" + ("%08X" % (base + sx * 4)).encode() + bytes(data))
    import random
    n = 0
    order = list(range(len(packets)))
    for p in range(passes):
        if p:                                      # shuffle later passes so phase-locked
            random.shuffle(order)                  # kernel drops hit different rows -> fill in
        for i in order:
            try:
                sock.sendto(packets[i], (ip, PORT))
            except (ConnectionResetError, OSError):
                pass
            n += 1
            if delay:
                time.sleep(delay)
    return n


def to_bgrx(pil_img, w, h):
    """Convert a PIL image to an (h, w, 4) BGRX array, resizing if needed."""
    img = pil_img.convert("RGB")
    if img.size != (w, h):
        img = img.resize((w, h), Image.LANCZOS)
    rgb = np.asarray(img, dtype=np.uint8)
    bgrx = np.zeros((h, w, 4), dtype=np.uint8)
    bgrx[..., 0] = rgb[..., 2]; bgrx[..., 1] = rgb[..., 1]; bgrx[..., 2] = rgb[..., 0]
    return bgrx


def blit_frame(ip, pil_img, w=DEF_W, h=DEF_H, pitch=DEF_PITCH, rle=True,
               passes=3, delay=0.0006, sock=None):
    """Blit an exact framebuffer-sized PIL image to the laptop (RLE by default)."""
    own = sock is None
    sock = sock or _sock()
    try:
        bgrx = to_bgrx(pil_img, w, h)
        if rle:
            return stream_rle(sock, ip, bgrx, pitch, passes, delay or 0.0005)
        return stream_bgrx(sock, ip, bgrx, pitch, passes, 180, delay)
    finally:
        if own:
            sock.close()


def blit_at(ip, pil_region, x, y, pitch=DEF_PITCH, sock=None, passes=3, delay=0.0004):
    """Blit a small region image to the framebuffer at (x, y) via raw G packets.
    Used for the reader cursor: a few scanlines, so it lands in a fraction of a second."""
    own = sock is None
    sock = sock or _sock()
    try:
        w, h = pil_region.width, pil_region.height
        bgrx = to_bgrx(pil_region, w, h)
        pkts = []
        for r in range(h):
            off = (y + r) * pitch + x * 4
            data = bgrx[r].tobytes()
            xx = 0
            while xx < w:
                n = min(187, w - xx)
                pkts.append(b"G" + ("%08X" % (off + xx * 4)).encode() + data[xx * 4: xx * 4 + n * 4])
                xx += n
        import random
        order = list(range(len(pkts)))
        for p in range(passes):
            if p:
                random.shuffle(order)
            for i in order:
                try:
                    sock.sendto(pkts[i], (ip, PORT))
                except (ConnectionResetError, OSError):
                    pass
                if delay:
                    time.sleep(delay)
    finally:
        if own:
            sock.close()


def show(src, ip=DEF_IP, mode="cover", enter=False, exit_after=False,
         passes=2, chunkpix=180, delay=0.0006, sock=None, rle=False):
    """High-level: query geometry, scale, optionally enter graphics, stream."""
    own = sock is None
    sock = sock or _sock()
    try:
        w, h, pitch, bpp = query_geometry(sock, ip)
        if enter:
            enter_graphics(sock, ip)
            time.sleep(0.2)
        bgrx = fit_image(src, w, h, mode)
        if rle:
            n = stream_rle(sock, ip, bgrx, pitch, passes, delay if delay else 0.0004)
        else:
            n = stream_bgrx(sock, ip, bgrx, pitch, passes, chunkpix, delay)
        if exit_after:
            exit_graphics(sock, ip)
        return w, h, pitch, bpp, n
    finally:
        if own:
            sock.close()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    ip, mode = DEF_IP, "cover"
    passes, chunkpix, delay = 2, 180, 0.0006
    enter = exit_after = False
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--fit", "--cover", "--stretch"):
            mode = a[2:]
        elif a == "--enter":
            enter = True
        elif a == "--exit":
            exit_after = True
        elif a == "--passes":
            i += 1; passes = int(args[i])
        elif a == "--chunk":
            i += 1; chunkpix = int(args[i])
        elif a == "--delay":
            i += 1; delay = float(args[i])
        elif not a.startswith("--"):
            ip = a
        i += 1
    t0 = time.time()
    w, h, pitch, bpp, n = show(path, ip, mode, enter, exit_after, passes, chunkpix, delay)
    dt = time.time() - t0
    print("framebuffer %dx%d pitch=%d bpp=%d -> %s:%d" % (w, h, pitch, bpp, ip, PORT))
    print("sent %d packets in %d pass(es), %.1fs (%.0f pkt/s)"
          % (n, passes, dt, n / dt if dt else 0))


if __name__ == "__main__":
    main()
