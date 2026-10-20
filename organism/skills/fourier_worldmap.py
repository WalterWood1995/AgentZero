#!/usr/bin/env python3
# skills/fourier_worldmap.py - the organism draws the WORLD MAP with a Fourier series.
#
# Same method as fourier_dario, but the single path is the world's coastline instead of
# a face: Natural Earth 110m land polygons (data/ne_110m_land.geojson), equirectangular,
# the biggest ~22 landmasses stitched into one pen stroke. THE OLD PC DOES THE MATHS -
# each frame the kernel's E command evaluates the 300-epicycle chain in integer fixed
# point on this machine's CPU; the dev PC only turns the returned points into pixels and
# blits them to the old PC's VBE framebuffer. Needs the EPI_MAX=300 kernel (m19).
#
# Usage (drive a running kernel):
#   python skills/fourier_worldmap.py <ip> [--frames F] [--epi N] [--render DIR]
# Offline reference render (no hardware):
#   python skills/fourier_worldmap.py --render out/   [--frames F]
import os, sys, json, time, math

HERE = os.path.dirname(os.path.abspath(__file__))
ORG = os.path.dirname(HERE)
sys.path.insert(0, ORG)                       # organism/ (hw.py, fourier.py)
sys.path.insert(0, os.path.dirname(ORG))      # baremetal/ (show_image.py)

import fourier
from hw import HW

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError:
    np = None

GEOJSON = os.path.join(ORG, "data", "ne_110m_land.geojson")
BG = (0, 6, 0); ARM = (0, 90, 40); TRACE = (150, 255, 170); PEN = (210, 255, 210)


def build_path(screen=(1024, 768), keep=22, antarctica=False, n_points=4000, fill=0.95):
    """Natural Earth land -> one ordered complex path z[n] (equirectangular, scaled)."""
    d = json.load(open(GEOJSON))
    rings = []
    for f in d["features"]:
        g = f["geometry"]; cs = g["coordinates"]
        for poly in ([cs] if g["type"] == "Polygon" else cs):
            rings.append(np.array(poly[0], float))        # exterior ring (lon, lat)
    rings.sort(key=lambda r: (r[:, 0].max() - r[:, 0].min()) * (r[:, 1].max() - r[:, 1].min()),
               reverse=True)
    rings = rings[:keep]
    if not antarctica:
        rings = [r for r in rings if r[:, 1].min() > -78]
    strokes = [np.stack([r[:, 0], -r[:, 1]], 1) for r in rings]   # equirectangular
    ordered = [strokes.pop(0)]
    while strokes:                                         # stitch, nearest ocean hop
        tail = ordered[-1][-1]
        best, bi, bf = 1e18, 0, False
        for i, s in enumerate(strokes):
            d0 = np.hypot(*(s[0] - tail)); d1 = np.hypot(*(s[-1] - tail))
            if d0 < best: best, bi, bf = d0, i, False
            if d1 < best: best, bi, bf = d1, i, True
        s = strokes.pop(bi); ordered.append(s[::-1] if bf else s)
    p = np.vstack(ordered)
    seg = np.sqrt((np.diff(p, axis=0) ** 2).sum(1)); arc = np.concatenate([[0], np.cumsum(seg)])
    want = np.linspace(0, arc[-1], n_points, endpoint=False)
    z = np.interp(want, arc, p[:, 0]) + 1j * np.interp(want, arc, p[:, 1])
    sw, sh = screen
    rx, ry = z.real, z.imag
    sc = min(sw * fill / max(rx.max() - rx.min(), 1), sh * fill / max(ry.max() - ry.min(), 1))
    return (z - ((rx.min() + rx.max()) / 2 + 1j * (ry.min() + ry.max()) / 2)) * sc + (sw / 2 + 1j * sh / 2)


def render_frame(pts, trace, w, h):
    img = Image.new("RGB", (w, h), BG); d = ImageDraw.Draw(img)
    d.line([c for p in pts for c in p], fill=ARM)          # faint 300-arm epicycle chain
    if len(trace) >= 2:
        d.line([c for p in trace for c in p], fill=TRACE, width=1)
    px, py = pts[-1]
    d.ellipse([px - 2, py - 2, px + 2, py + 2], fill=PEN)
    return img


def _sched(period, frames):
    if frames >= period:
        return list(range(period))
    return [int(round(i * period / frames)) % period for i in range(frames)]


def run(ip="127.0.0.1", n_epi=300, frames=512, enter=True, passes=2, delay=0.0006,
        render_dir=None, verbose=True):
    import show_image
    hw = HW(ip)
    w, h, pitch, bpp = show_image.query_geometry(show_image._sock(), ip) if ip else (1024, 768, 4096, 32)
    z = build_path(screen=(w, h))
    epis, cx, cy, P = fourier.dft_epicycles(z, n_epi=n_epi)
    if verbose:
        print("world map: epicycles=%d period=%d centre=(%.0f,%.0f) screen=%dx%d"
              % (len(epis), P, cx, cy, w, h))
    if ip:
        if not hw.load(fourier.COEF_BASE, fourier.encode_coeffs(epis, cx, cy, P)):
            print("coeff load failed"); return False
        if not hw.load(fourier.SIN_BASE, fourier.sine_table()):
            print("sine load failed"); return False
        if verbose:
            print("loaded coeffs + sine table into the old PC's RAM")
    sock = show_image._sock() if ip else None
    if ip and enter:
        show_image.enter_graphics(sock, ip)
    if render_dir:
        os.makedirs(render_dir, exist_ok=True)
    sintab = fourier.sine_table_ints()
    trace = []
    for fi, t in enumerate(_sched(P, frames)):
        pts = hw.fourier(t) if ip else None
        if not pts:
            pts = fourier.eval_ref(epis, cx, cy, P, t, sintab)   # ride out a dropped reply
        trace.append(pts[-1])
        img = render_frame(pts, trace, w, h)
        if render_dir:
            img.save(os.path.join(render_dir, "f%04d.png" % fi))
        if ip:
            show_image.blit_frame(ip, img, w, h, pitch, rle=True, passes=passes, delay=delay, sock=sock)
        if verbose and fi % 16 == 0:
            print("  frame %d/%d  t=%d  pen=%s" % (fi, frames, t, pts[-1]))
    if verbose:
        print("done: world map drawn by %d epicycles, computed on the old PC's CPU" % len(epis))
    return True


if __name__ == "__main__":
    a = sys.argv[1:]
    ip, frames, n_epi, render_dir = None, 512, 300, None
    i = 0
    while i < len(a):
        if a[i] == "--frames": i += 1; frames = int(a[i])
        elif a[i] == "--epi": i += 1; n_epi = int(a[i])
        elif a[i] == "--render": i += 1; render_dir = a[i]
        elif a[i].count(".") == 3: ip = a[i]
        i += 1
    run(ip or "", n_epi=n_epi, frames=frames, enter=bool(ip), render_dir=render_dir)
