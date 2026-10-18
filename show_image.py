#!/usr/bin/env python3
# show_image.py - stream a photo to the AgentZero bare-metal kernel's VBE linear
# framebuffer over UDP, so an OS-less laptop displays a full-screen high-res image.
#
# The dev PC does all the heavy lifting (decode / scale / BGRX conversion); the
# kernel just copies raw pixel bytes into the framebuffer. Protocol (UDP :50000):
#   Q                               -> kernel replies 16 bytes: <w h pitch bpp> (LE)
#   G<8 hex LFB byte offset><bytes>  -> kernel writes those bytes at that FB offset
#
# Build/run the kernel with IMAGE_DEMO=1 (graphics kernel) and PXE-boot the laptop.
#
# Usage:
#   python show_image.py <image> [old-pc-ip] [--fit|--cover|--stretch]
#                                 [--passes N] [--chunk PIXELS] [--delay SEC]
import socket, struct, sys, time

try:
    from PIL import Image
    import numpy as np
except ImportError:
    sys.exit("needs Pillow + numpy:  pip install pillow numpy")

PORT       = 50000
DEF_IP     = "192.168.178.114"      # old Asus (see memory)
DEF_W, DEF_H, DEF_PITCH, DEF_BPP = 1024, 768, 1024 * 4, 32


def query_geometry(sock, ip):
    """Ask the kernel for its real framebuffer geometry; fall back to defaults."""
    try:
        sock.sendto(b"Q", (ip, PORT))
        sock.settimeout(1.5)
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
    print("  (no geometry reply; assuming %dx%d pitch=%d bpp=%d)"
          % (DEF_W, DEF_H, DEF_PITCH, DEF_BPP))
    return DEF_W, DEF_H, DEF_PITCH, DEF_BPP


def fit_image(path, w, h, mode):
    img = Image.open(path).convert("RGB")
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
    return bgrx                                       # (h, w, 4)  X = 0


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    ip = DEF_IP
    mode = "cover"
    passes, chunkpix, delay = 2, 180, 0.0006
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--fit", "--cover", "--stretch"):
            mode = a[2:]
        elif a == "--passes":
            i += 1; passes = int(args[i])
        elif a == "--chunk":
            i += 1; chunkpix = int(args[i])
        elif a == "--delay":
            i += 1; delay = float(args[i])
        elif not a.startswith("--"):
            ip = a
        i += 1

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    w, h, pitch, bpp = query_geometry(sock, ip)
    print("framebuffer %dx%d pitch=%d bpp=%d  ->  %s:%d" % (w, h, pitch, bpp, ip, PORT))
    if bpp != 32:
        print("  WARNING: kernel reports %d bpp; show_image only emits 32-bpp BGRX" % bpp)

    bgrx = fit_image(path, w, h, mode)               # (h, w, 4)
    rowbytes = w * 4
    maxpix = min(chunkpix, 187)                       # keep packet <= 760 (9 hdr + 748)

    npkt = 0
    t0 = time.time()
    for _ in range(passes):
        for y in range(h):
            row = bgrx[y].tobytes()                   # rowbytes long, this scanline only
            base = y * pitch                          # never span the pitch gap
            x = 0
            while x < w:
                n = min(maxpix, w - x)
                off = base + x * 4
                payload = row[x * 4: x * 4 + n * 4]
                pkt = b"G" + ("%08X" % off).encode() + payload
                try:
                    sock.sendto(pkt, (ip, PORT))
                except (ConnectionResetError, OSError):
                    pass
                npkt += 1
                if delay:
                    time.sleep(delay)
                x += n
    dt = time.time() - t0
    print("sent %d packets in %d pass(es), %.1fs (%.0f pkt/s)"
          % (npkt, passes, dt, npkt / dt if dt else 0))


if __name__ == "__main__":
    main()
