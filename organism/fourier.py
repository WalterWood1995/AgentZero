#!/usr/bin/env python3
# fourier.py - THE METHOD (provided by the Claude brain; the real running maths is
# done by the old PC's CPU via the kernel's L/E commands, see hw.py.load/fourier).
#
# Pipeline: a portrait photo -> one ordered closed contour (a complex path z[n]) ->
# DFT -> a set of rotating vectors ("epicycles": frequency, radius, phase) -> fixed
# point (int) coefficients + an integer sine table that the organism loads into the
# old PC's RAM. The old PC then evaluates the Fourier series (the epicycle chain) in
# integer fixed point on its own CPU, one frame at a time.
#
# This file is pure maths + encoding; it never touches hardware. The matching integer
# reference eval_ref() mirrors the kernel's E command bit-for-bit so a test can prove
# the old PC computes the same points.
import math

# must match stage2.asm
COEF_BASE = 0x00100000
SIN_BASE  = 0x00120000
SIN_LEN   = 1024          # sine table entries (power of two)
SIN_SHIFT = 14            # sine fixed-point scale = 1<<14
SIN_QUARTER = SIN_LEN // 4


def _i32(x):
    """wrap to signed 32-bit, as the kernel's 32-bit registers/memory do."""
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def _i16(x):
    x &= 0xFFFF
    return x - (1 << 16) if x & 0x8000 else x


def sine_table():
    """int32 Q14 sine table, SIN_LEN entries over [0, 2pi). bytes, little-endian."""
    out = bytearray()
    scale = 1 << SIN_SHIFT
    for i in range(SIN_LEN):
        v = int(round(math.sin(2 * math.pi * i / SIN_LEN) * scale))
        out += _i32(v).to_bytes(4, "little", signed=True)
    return bytes(out)


def sine_table_ints():
    scale = 1 << SIN_SHIFT
    return [int(round(math.sin(2 * math.pi * i / SIN_LEN) * scale)) for i in range(SIN_LEN)]


def encode_coeffs(epicycles, cx, cy, period):
    """epicycles: list of (freq, radius_px, phase_rad). Returns the COEF_BASE blob:
    header {N, cx, cy, reserved} then N x {amp, wstep(Q8), phase0(table idx)}."""
    n = len(epicycles)
    blob = bytearray()
    blob += _i32(n).to_bytes(4, "little", signed=True)
    blob += _i32(int(round(cx))).to_bytes(4, "little", signed=True)
    blob += _i32(int(round(cy))).to_bytes(4, "little", signed=True)
    blob += _i32(0).to_bytes(4, "little", signed=True)
    for freq, radius, phase in epicycles:
        amp = int(round(radius))
        # (wstep * t) >> 8 must equal freq * t * SIN_LEN / period  ->  wstep = freq*SIN_LEN*256/period
        wstep = int(round(freq * SIN_LEN * 256 / period))
        phase0 = int(round(phase / (2 * math.pi) * SIN_LEN)) % SIN_LEN
        blob += _i32(amp).to_bytes(4, "little", signed=True)
        blob += _i32(wstep).to_bytes(4, "little", signed=True)
        blob += _i32(phase0).to_bytes(4, "little", signed=True)
    return bytes(blob)


def eval_ref(epicycles, cx, cy, period, t, sintab=None):
    """Integer reference that mirrors the kernel E command EXACTLY (for validation).
    Returns the (N+1) points: centre, then each epicycle centre up to the pen tip."""
    if sintab is None:
        sintab = sine_table_ints()
    cx, cy = int(round(cx)), int(round(cy))
    pts = [(_i16(cx), _i16(cy))]
    xacc = yacc = 0
    for freq, radius, phase in epicycles:
        amp = int(round(radius))
        wstep = int(round(freq * SIN_LEN * 256 / period))
        phase0 = int(round(phase / (2 * math.pi) * SIN_LEN)) % SIN_LEN
        idx = _i32(((_i32(wstep * t) >> 8) + phase0)) & (SIN_LEN - 1)
        s = sintab[idx]
        c = sintab[(idx + SIN_QUARTER) & (SIN_LEN - 1)]
        xacc = _i32(xacc + _i32(amp * c))
        yacc = _i32(yacc + _i32(amp * s))
        px = _i16((xacc >> SIN_SHIFT) + cx)
        py = _i16((yacc >> SIN_SHIFT) + cy)
        pts.append((px, py))
    return pts


# ----------------------------- image -> epicycles -----------------------------

def extract_path(image_path, n_points=600, screen=(1024, 768), fill=0.82,
                 max_strokes=10, crop=0.86):
    """Photo -> one ordered path that traces the portrait's main edges, resampled to
    n_points, scaled/centred to the screen, as a complex array z[n] = x + i*y (pixels).
    The longest edge contours (face outline, hair, eyes, nose, mouth) are stitched into
    a single stroke by nearest-endpoint ordering, so the epicycles draw a face, not one
    blob. Small connecting hops between strokes are normal for Fourier line drawings."""
    import cv2
    import numpy as np
    # cv2.imread fails on non-ASCII Windows paths (e.g. "JEV 系统"); decode bytes.
    buf = np.fromfile(image_path, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise SystemExit("cannot read %s" % image_path)
    # focus on the central portrait, drop the busy background frame
    h0, w0 = img.shape
    cw, ch = int(w0 * crop), int(h0 * crop)
    x0, y0 = (w0 - cw) // 2, (h0 - ch) // 2
    img = img[y0:y0 + ch, x0:x0 + cw]
    img = cv2.bilateralFilter(img, 7, 60, 60)
    edges = cv2.Canny(img, 40, 120)
    edges = cv2.dilate(edges, np.ones((2, 2), np.uint8), iterations=1)
    cnts, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    if not cnts:
        raise SystemExit("no contours found")
    # keep the longest few contours (by perimeter) = the strong facial edges
    strokes = sorted(cnts, key=lambda c: cv2.arcLength(c, False), reverse=True)
    strokes = [c.reshape(-1, 2).astype(float) for c in strokes[:max_strokes]
               if cv2.arcLength(c, False) > 40]
    if not strokes:
        strokes = [max(cnts, key=cv2.arcLength).reshape(-1, 2).astype(float)]
    # order strokes greedily by nearest endpoint, flipping each to minimise the hop;
    # drop a stroke whose nearest endpoint is too far (avoids long stray jump lines)
    hop_cap = 0.30 * max(cw, ch)
    ordered = [strokes.pop(0)]
    while strokes:
        tail = ordered[-1][-1]
        best, bi, bflip = 1e18, 0, False
        for i, s in enumerate(strokes):
            d0 = np.hypot(*(s[0] - tail))
            d1 = np.hypot(*(s[-1] - tail))
            if d0 < best:
                best, bi, bflip = d0, i, False
            if d1 < best:
                best, bi, bflip = d1, i, True
        s = strokes.pop(bi)
        if best > hop_cap and len(ordered) >= 4:
            continue                       # too far: skip this stroke, keep drawing clean
        ordered.append(s[::-1] if bflip else s)
    pts = np.vstack(ordered)
    # resample to n_points evenly along arc length
    seg = np.sqrt(((np.diff(pts, axis=0)) ** 2).sum(1))
    arc = np.concatenate([[0], np.cumsum(seg)])
    total = arc[-1]
    if total == 0:
        raise SystemExit("degenerate contour")
    want = np.linspace(0, total, n_points, endpoint=False)
    rx = np.interp(want, arc, pts[:, 0])
    ry = np.interp(want, arc, pts[:, 1])
    z = rx + 1j * ry
    # scale + centre to the screen
    sw, sh = screen
    w = rx.max() - rx.min()
    h = ry.max() - ry.min()
    scale = min(sw * fill / max(w, 1), sh * fill / max(h, 1))
    cxp = (rx.min() + rx.max()) / 2
    cyp = (ry.min() + ry.max()) / 2
    z = (z - (cxp + 1j * cyp)) * scale + (sw / 2 + 1j * sh / 2)
    return z


def dft_epicycles(z, n_epi=64):
    """z[n] complex path -> (epicycles, cx, cy, period). epicycles = top n_epi rotating
    vectors (freq, radius_px, phase_rad) by radius, excluding the DC term, which becomes
    the centre (cx, cy)."""
    import numpy as np
    P = len(z)
    c = np.fft.fft(z) / P
    cx, cy = c[0].real, c[0].imag
    terms = []
    for k in range(1, P):
        freq = k if k <= P // 2 else k - P          # map to signed frequency
        terms.append((freq, abs(c[k]), math.atan2(c[k].imag, c[k].real)))
    terms.sort(key=lambda e: e[1], reverse=True)
    return terms[:n_epi], cx, cy, P


def prepare(image_path, n_epi=64, screen=(1024, 768), n_points=512):
    """Full method: image -> (coef_blob, sine_blob, meta) ready for hw.load()."""
    z = extract_path(image_path, n_points=n_points, screen=screen)
    epis, cx, cy, P = dft_epicycles(z, n_epi=n_epi)
    coef = encode_coeffs(epis, cx, cy, P)
    meta = {"n_epi": len(epis), "cx": cx, "cy": cy, "period": P,
            "epicycles": epis, "screen": screen}
    return coef, sine_table(), meta


if __name__ == "__main__":
    import sys
    img = sys.argv[1] if len(sys.argv) > 1 else "dario.jpg"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    coef, sin_blob, meta = prepare(img, n_epi=n)
    print("epicycles:", meta["n_epi"], "period:", meta["period"],
          "centre: (%.0f, %.0f)" % (meta["cx"], meta["cy"]))
    print("coef blob:", len(coef), "bytes  sine table:", len(sin_blob), "bytes")
    print("top 5 (freq, radius_px, phase):")
    for e in meta["epicycles"][:5]:
        print("  freq=%+d  r=%.1f  phase=%.2f" % e)
