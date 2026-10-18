#!/usr/bin/env python3
# skills/fourier_dario.py - the organism draws Dario with a Fourier series.
#
# THE OLD PC DOES THE MATHS: each frame, the kernel's E command evaluates the
# preloaded epicycle chain in integer fixed point on this machine's CPU and returns
# the chain of points (centre -> each turning wheel's centre -> the pen tip). The dev
# PC only turns those numbers into pixels (the old PC has no graphics library, it just
# blits a framebuffer) - it draws the turning wheels, the connecting arms, the growing
# pen trace (Dario's outline) and the real/imaginary waveforms, and streams each frame
# to the old PC's VBE framebuffer.
#
# Usage (drive a running kernel):
#   python skills/fourier_dario.py <image> <ip> [--epi N] [--frames F] [--enter]
# Render frames to PNGs offline (no hardware), using the SAME old-PC fixed-point
# points if an ip is given, else the Python reference:
#   python skills/fourier_dario.py <image> --render <dir> [--epi N] [--frames F]
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORG = os.path.dirname(HERE)
sys.path.insert(0, ORG)                       # organism/ (hw.py, fourier.py)
sys.path.insert(0, os.path.dirname(ORG))      # baremetal/ (show_image.py)

import fourier
from hw import HW

try:
    from PIL import Image, ImageDraw
except ImportError:
    Image = None

# Matrix-green palette
BG     = (0, 6, 0)
WHEEL  = (0, 70, 0)
ARM    = (0, 150, 40)
TRACE  = (130, 255, 150)
WAVE   = (0, 170, 90)
PEN    = (200, 255, 200)


def render_frame(pts, trace, w, h, waveform=None):
    """pts: the epicycle chain [centre, c1, ..., pen] for this frame (old-PC computed).
    trace: all pen tips so far. Returns a PIL RGB frame."""
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    # turning wheels + arms (each epicycle: circle at its centre, radius = next hop)
    for k in range(len(pts) - 1):
        cx, cy = pts[k]
        nx, ny = pts[k + 1]
        r = int(round(math.hypot(nx - cx, ny - cy)))
        if r > 1:
            d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHEEL)
        d.line([cx, cy, nx, ny], fill=ARM)
    # the growing pen trace = Dario's outline
    if len(trace) >= 2:
        d.line([p for pt in trace for p in pt], fill=TRACE, width=2)
    # pen tip marker
    px, py = pts[-1]
    d.ellipse([px - 3, py - 3, px + 3, py + 3], fill=PEN)
    # real/imaginary waveforms along the bottom (the signal the epicycles synthesise)
    if waveform and len(waveform) >= 2:
        n = len(waveform)
        y0 = h - 70
        xs = [int(i * (w - 1) / (n - 1)) for i in range(n)]
        xw = [(xs[i], y0 - int((waveform[i][0]) * 50)) for i in range(n)]
        yw = [(xs[i], y0 + 1 + int((waveform[i][1]) * 50)) for i in range(n)]
        d.line([p for pt in xw for p in pt], fill=WAVE)
        d.line([p for pt in yw for p in pt], fill=(90, 120, 200))
    return img


def _schedule(period, frames):
    if frames >= period:
        return list(range(period))
    return [int(round(i * period / frames)) % period for i in range(frames)]


def run(image, ip="127.0.0.1", n_epi=64, frames=64, enter=True,
        passes=1, delay=0.0004, render_dir=None, verbose=True):
    """Load the epicycles, then animate: each frame the OLD PC computes the chain
    (E), the dev PC renders and blits it. render_dir => also save frame PNGs."""
    import show_image
    hw = HW(ip)
    w, h, pitch, bpp = show_image.query_geometry(show_image._sock(), ip) \
        if ip else (1024, 768, 4096, 32)
    coef, sin_blob, meta = fourier.prepare(image, n_epi=n_epi, screen=(w, h))
    if verbose:
        print("epicycles=%d period=%d centre=(%.0f,%.0f) screen=%dx%d"
              % (meta["n_epi"], meta["period"], meta["cx"], meta["cy"], w, h))
    if ip:
        if not hw.load(fourier.COEF_BASE, coef):
            print("coeff load failed"); return False
        if not hw.load(fourier.SIN_BASE, sin_blob):
            print("sine load failed"); return False
        if verbose:
            print("loaded coeffs + sine table into the old PC's RAM")
    sock = show_image._sock() if ip else None
    if ip and enter:
        show_image.enter_graphics(sock, ip)
    if render_dir:
        os.makedirs(render_dir, exist_ok=True)
    sintab = fourier.sine_table_ints()
    period = meta["period"]
    trace = []
    wave = []
    sched = _schedule(period, frames)
    amp_ref = max(1.0, max(abs(meta["cx"]), 1))
    for fi, t in enumerate(sched):
        if ip:
            pts = hw.fourier(t)                 # <-- the OLD PC computes the points
            if not pts:
                pts = fourier.eval_ref(meta["epicycles"], meta["cx"], meta["cy"],
                                       period, t, sintab)   # ride out a dropped reply
        else:
            pts = fourier.eval_ref(meta["epicycles"], meta["cx"], meta["cy"],
                                   period, t, sintab)
        trace.append(pts[-1])
        wave.append(((pts[-1][0] - meta["cx"]) / 120.0, (pts[-1][1] - meta["cy"]) / 120.0))
        img = render_frame(pts, trace, w, h, waveform=wave[-120:])
        if render_dir:
            img.save(os.path.join(render_dir, "f%04d.png" % fi))
        if ip:
            show_image.blit_frame(ip, img, w, h, pitch, rle=True,
                                  passes=passes, delay=delay, sock=sock)
        if verbose and fi % 8 == 0:
            print("  frame %d/%d  t=%d  pen=%s" % (fi, len(sched), t, pts[-1]))
    if verbose:
        print("done: Dario drawn by %d epicycles, computed on the old PC's CPU"
              % meta["n_epi"])
    return True


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit("usage: fourier_dario.py <image> [ip] [--epi N] [--frames F] "
                 "[--enter] [--render DIR]")
    image = a[0]
    ip = None
    n_epi, frames, enter, render_dir = 64, 64, False, None
    i = 1
    while i < len(a):
        if a[i] == "--epi":
            i += 1; n_epi = int(a[i])
        elif a[i] == "--frames":
            i += 1; frames = int(a[i])
        elif a[i] == "--enter":
            enter = True
        elif a[i] == "--render":
            i += 1; render_dir = a[i]
        elif not a[i].startswith("--"):
            ip = a[i]
        i += 1
    run(image, ip or "", n_epi=n_epi, frames=frames, enter=enter, render_dir=render_dir)
