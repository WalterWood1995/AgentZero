#!/usr/bin/env python3
# nn_qemu_test.py - bit-exact check of the kernel's nn_render ('i' command) against
# nnascii.infer_q: boot pxe_cam.img in QEMU, L-load weights.bin at NN_W, send a grey
# grid (Dario) with 'i' packets, read the text buffer back with M and compare every cell.
#   PYTHONUTF8=1 python nnascii/nn_qemu_test.py [ip]   (an ip = real machine, no QEMU)
import os, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BM = os.path.dirname(HERE)
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(BM, "organism"))
import nnascii

VGA, SCR_COLS, SCR_ROWS = 0x20000, 128, 96
UDP, QMP = 50031, 55631


def grey_grid(cols, rows):
    import cv2
    g = cv2.cvtColor(cv2.imdecode(np.fromfile(os.path.join(BM, "dario.jpg"), dtype=np.uint8), cv2.IMREAD_COLOR),
                     cv2.COLOR_BGR2GRAY)
    g = nnascii.preprocess(cv2.resize(g, (cols * 8, rows * 8), interpolation=cv2.INTER_AREA))
    return g.reshape(rows, 8, cols, 8).mean(axis=(1, 3)).astype(np.uint8)


def read_fb_rows(hw, pitch, y0, y1, w=SCR_COLS * 8):
    """Y-read framebuffer scanlines y0..y1 (no echo on the console, unlike M)."""
    out = np.zeros((y1 - y0, w, 4), dtype=np.uint8)
    CH = 1400 // 4 * 4
    for y in range(y0, y1):
        x = 0
        while x < w * 4:
            n = min(CH, w * 4 - x)
            d = None
            for _ in range(4):
                hw.s.sendto(b"Y%08X%04X" % (y * pitch + x, n), (hw.ip, hw.port))
                try:
                    r, _ = hw.s.recvfrom(2048)
                    if len(r) == n:
                        d = r; break
                except OSError:
                    pass
            assert d is not None, "Y read failed at y=%d" % y
            out[y - y0, x // 4:(x + n) // 4] = np.frombuffer(d, dtype=np.uint8).reshape(-1, 4)
            x += n
    return out


def decode_cells(px, font, glyphs):
    """8x8 pixel blocks -> (char, tier) using the kernel's font; None if no glyph matches."""
    masks = {}
    for ch in glyphs:
        rows = font[ord(ch) * 8:ord(ch) * 8 + 8]
        masks[ch] = np.array([[1 if b & (0x80 >> x) else 0 for x in range(8)] for b in rows], dtype=np.uint8)
    H, W = px.shape[0] // 8, px.shape[1] // 8
    chars, tiers = [], []
    for r in range(H):
        line, tl = [], []
        for c in range(W):
            blk = px[r * 8:r * 8 + 8, c * 8:c * 8 + 8]
            lit = (blk[..., 1] > 0).astype(np.uint8)
            ch = next((k for k, m in masks.items() if np.array_equal(m, lit)), "?")
            g = int(blk[..., 1].max()); rb = int(blk[..., 0].max())
            tier = 0 if g == 0 else (3 if rb > 0 else (2 if g > 0x80 else 1))
            line.append(ch); tl.append(tier)
        chars.append("".join(line)); tiers.append(tl)
    return chars, tiers


def run(hw, screenshot=None):
    import struct
    blob = open(nnascii.WEIGHTS, "rb").read()
    assert hw.load(nnascii.NN_W_ADDR, blob, chunk=512, verify=True), "L weights failed"
    glyphs = nnascii.unpack(blob)[4]
    # the kernel's own ROM font (QEMU's differs from the Asus one in a few glyphs)
    font_addr = int(os.environ.get("FONT_BUF", "0"), 16)
    if font_addr:
        font = b"".join(hw.mem(font_addr + o, 128) for o in range(0, 2048, 128))
    else:
        font = open(nnascii.FONT, "rb").read()
    hw.s.sendto(b"Q\0", (hw.ip, hw.port)); d, _ = hw.s.recvfrom(64)
    w, h, pitch, bpp = struct.unpack("<4I", d[:16])
    x0, y0 = max(0, (w - SCR_COLS * 8) // 2), max(0, (h - SCR_ROWS * 8) // 2)
    hw.s.sendto(b"X\0", (hw.ip, hw.port)); time.sleep(0.3)
    cells = grey_grid(64, 64)
    full = np.zeros((SCR_ROWS, SCR_COLS), dtype=np.uint8)
    full[:64, :64] = cells
    rows_per = (700 - 4) // SCR_COLS                  # 5 rows = 644 B per packet
    t0 = time.time()
    for r in range(0, SCR_ROWS, rows_per):
        last = r + rows_per >= SCR_ROWS
        hw.s.sendto(b"i%02X%d" % (r, 1 if last else 0) + full[r:r + rows_per].tobytes(), (hw.ip, hw.port))
        time.sleep(0.002)
    time.sleep(1.0)                                   # let the old PC run the net + repaint
    chars, tiers = nnascii.infer_q(full, blob)
    px = read_fb_rows(hw, pitch, y0, y0 + 64 * 8)     # the 64 portrait rows (x0 = 0 on 1024-wide)
    kchars, ktiers = decode_cells(px[:, x0:x0 + SCR_COLS * 8], font, glyphs)
    bad = 0
    for r in range(64):
        for c in range(SCR_COLS):
            want_t = tiers[r][c] if chars[r][c] != " " else 0
            if kchars[r][c] != chars[r][c] or ktiers[r][c] != want_t:
                bad += 1
                if bad <= 5:
                    print("  mismatch r%d c%d: kernel %r/%d ref %r/%d" % (r, c, kchars[r][c], ktiers[r][c], chars[r][c], want_t))
    print("cells compared %d, mismatches %d  (%s)" % (64 * SCR_COLS, bad, "BIT-EXACT" if bad == 0 else "DIFF"))
    for ln in kchars[:64]:
        print(ln[:64])
    return bad == 0


def main():
    from hw import HW
    if len(sys.argv) > 1 and sys.argv[1].count(".") == 3:
        hw = HW(sys.argv[1], port=50000, timeout=1.5)
        ok = run(hw)
    else:
        from qemu_dev import QemuKernel
        with QemuKernel(udp_port=UDP, qmp_port=QMP, img="pxe_cam.img", boot_wait=18) as k:
            hw = HW("127.0.0.1", port=UDP, timeout=2.0)
            ok = run(hw)
            k.screenshot(os.path.join(os.environ.get("TEMP", "."), "nn_qemu.png"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
