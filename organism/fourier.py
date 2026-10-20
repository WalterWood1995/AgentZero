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
import os

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

def extract_path(image_path, n_points=1000, screen=(1024, 768), fill=0.88,
                 max_strokes=28, crop=0.98):
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
    # finer Canny (25/75) + no dilation keeps the glasses as clean round loops - the
    # single most recognisable Dario feature - instead of smearing them into the hair.
    edges = cv2.Canny(img, 25, 75)
    cnts, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    if not cnts:
        raise SystemExit("no contours found")
    # keep the longest few contours (by perimeter) = the strong facial edges
    strokes = sorted(cnts, key=lambda c: cv2.arcLength(c, False), reverse=True)
    strokes = [c.reshape(-1, 2).astype(float) for c in strokes[:max_strokes]
               if cv2.arcLength(c, False) > 20]
    if not strokes:
        strokes = [max(cnts, key=cv2.arcLength).reshape(-1, 2).astype(float)]
    # order strokes greedily by nearest endpoint, flipping each to minimise the hop;
    # drop a stroke whose nearest endpoint is too far (avoids long stray jump lines)
    hop_cap = 0.15 * max(cw, ch)
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


FACE_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "models", "face_landmarker.task")


def _order_chain(conns):
    """Order a mediapipe connection set (Connection(start,end) edges) into one vertex
    sequence, walking shared endpoints (a cycle for eyes/lips/oval, a path for brows)."""
    edges = [(c.start, c.end) for c in conns]
    adj = {}
    for a, b in edges:
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)
    start = next((n for n, nb in adj.items() if len(nb) == 1), edges[0][0])
    seq, used, cur, prev = [start], set(), start, None
    while True:
        nxt = next((x for x in adj[cur] if x != prev
                    and (min(cur, x), max(cur, x)) not in used), None)
        if nxt is None:
            break
        used.add((min(cur, nxt), max(cur, nxt)))
        seq.append(nxt); prev, cur = cur, nxt
        if nxt == start:
            break
    return seq


def extract_path_landmarks(image_path, model_path=None, screen=(1024, 768),
                           n_points=1400, fill=0.9, hair=True, glasses=True):
    """Photo -> one ordered path using a face-mesh (mediapipe): clean jaw/chin, nose,
    lips and eyebrows (the features a raw Canny contour misses), round glasses over the
    eyes, and the curly-hair silhouette from Canny on top. Needs the face_landmarker
    model; raises if mediapipe or the model is unavailable so the caller can fall back."""
    import numpy as np, cv2, math as _m, tempfile
    from mediapipe.tasks.python.vision import (FaceLandmarker, FaceLandmarkerOptions,
                                               FaceLandmarksConnections as FC)
    from mediapipe.tasks.python.core.base_options import BaseOptions
    import mediapipe as mp
    model_path = os.path.abspath(model_path or FACE_MODEL)
    buf = np.fromfile(image_path, dtype=np.uint8)
    bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    h, w = bgr.shape[:2]
    # mediapipe's runfiles check reads the CWD and aborts on a non-ASCII path (e.g.
    # "JEV 系统"); run detection from an ASCII temp dir, then restore.
    # Load the model as bytes: mediapipe's C file-open can't handle a non-ASCII path
    # (e.g. "JEV 系统"), but Python can read the file and hand over the buffer.
    with open(model_path, "rb") as _f:
        model_buf = _f.read()
    _cwd = os.getcwd()
    try:
        os.chdir(tempfile.gettempdir())
        opt = FaceLandmarkerOptions(base_options=BaseOptions(model_asset_buffer=model_buf),
                                    num_faces=1)
        det = FaceLandmarker.create_from_options(opt)
        res = det.detect(mp.Image(image_format=mp.ImageFormat.SRGB,
                                  data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
    finally:
        os.chdir(_cwd)
    if not res.face_landmarks:
        raise ValueError("no face detected")
    lm = res.face_landmarks[0]
    pts = np.array([[p.x * w, p.y * h] for p in lm])

    def poly(group):
        return pts[_order_chain(group)]

    strokes = []
    if hair:
        gray = cv2.imdecode(buf, cv2.IMREAD_GRAYSCALE)
        brow_y = pts[[70, 63, 105, 66, 107, 336, 296, 334, 293, 300], 1].min()
        ov = pts[[c.start for c in FC.FACE_LANDMARKS_FACE_OVAL]]
        x0, x1 = int(ov[:, 0].min()), int(ov[:, 0].max())
        top = cv2.bilateralFilter(gray[0:int(brow_y), x0:x1], 7, 50, 50)
        e = cv2.dilate(cv2.Canny(top, 30, 90), np.ones((3, 3), np.uint8), 1)
        cnts, _ = cv2.findContours(e, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        for c in sorted(cnts, key=lambda c: cv2.arcLength(c, False), reverse=True)[:4]:
            if cv2.arcLength(c, False) > 120:
                s = c.reshape(-1, 2).astype(float)
                k = 9
                s = np.stack([np.convolve(s[:, 0], np.ones(k) / k, "same"),
                              np.convolve(s[:, 1], np.ones(k) / k, "same")], 1)[k:-k]
                s[:, 0] += x0
                strokes.append(s)
    strokes += [poly(FC.FACE_LANDMARKS_FACE_OVAL),
                poly(FC.FACE_LANDMARKS_LEFT_EYEBROW),
                poly(FC.FACE_LANDMARKS_RIGHT_EYEBROW),
                poly(FC.FACE_LANDMARKS_NOSE),
                poly(FC.FACE_LANDMARKS_LIPS)]
    if glasses:
        lc = pts[[33, 133, 159, 145]].mean(0)
        rc = pts[[362, 263, 386, 374]].mean(0)
        rad = 0.62 * np.hypot(*(rc - lc)) / 2 * 1.7
        a = np.linspace(0, 2 * _m.pi, 48)
        strokes.append(np.stack([lc[0] + rad * np.cos(a), lc[1] + rad * np.sin(a)], 1))
        strokes.append(np.stack([rc[0] + rad * np.cos(a), rc[1] + rad * np.sin(a)], 1))
        strokes.append(np.array([lc + [rad * 0.55, 0], rc - [rad * 0.55, 0]]))
    else:
        strokes += [poly(FC.FACE_LANDMARKS_LEFT_EYE), poly(FC.FACE_LANDMARKS_RIGHT_EYE)]

    # stitch strokes greedily by nearest endpoint into one pen path
    strokes = [s for s in strokes if len(s) >= 2]
    ordered = [strokes.pop(0)]
    while strokes:
        tail = ordered[-1][-1]
        best, bi, bflip = 1e18, 0, False
        for i, s in enumerate(strokes):
            d0 = np.hypot(*(s[0] - tail)); d1 = np.hypot(*(s[-1] - tail))
            if d0 < best: best, bi, bflip = d0, i, False
            if d1 < best: best, bi, bflip = d1, i, True
        s = strokes.pop(bi)
        ordered.append(s[::-1] if bflip else s)
    p = np.vstack(ordered)
    seg = np.sqrt(((np.diff(p, axis=0)) ** 2).sum(1))
    arc = np.concatenate([[0], np.cumsum(seg)])
    want = np.linspace(0, arc[-1], n_points, endpoint=False)
    rx = np.interp(want, arc, p[:, 0]); ry = np.interp(want, arc, p[:, 1])
    z = rx + 1j * ry
    sw, sh = screen
    scale = min(sw * fill / max(rx.max() - rx.min(), 1),
                sh * fill / max(ry.max() - ry.min(), 1))
    cxp = (rx.min() + rx.max()) / 2; cyp = (ry.min() + ry.max()) / 2
    return (z - (cxp + 1j * cyp)) * scale + (sw / 2 + 1j * sh / 2)


def prepare(image_path, n_epi=96, screen=(1024, 768), n_points=1000, landmarks=True):
    """Full method: image -> (coef_blob, sine_blob, meta) ready for hw.load().
    n_epi=96 matches the kernel's EPI_MAX ceiling (more vectors = finer likeness).
    Prefers the face-mesh path (clean nose/mouth/chin + glasses); falls back to the
    Canny outline if mediapipe or the model is unavailable."""
    z = None
    if landmarks:
        try:
            z = extract_path_landmarks(image_path, screen=screen, n_points=max(n_points, 1400))
        except Exception as e:
            msg = ("landmark extract failed (%s); using Canny outline" % e)
            print(msg.encode("ascii", "replace").decode("ascii"))
    if z is None:
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
