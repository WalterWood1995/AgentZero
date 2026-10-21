#!/usr/bin/env python3
# nnascii.py - a tiny neural network that turns a grey cell grid into ASCII art, trained
# on this PC and RUN BY THE OLD PC's CPU (kernel 'i' command, fixed-point MLP).
#
#   input  : the 3x3 neighbourhood of grey cells (0..255 each, one cell = one 8x8 block)
#   output : one of NG glyphs of the Asus ROM font (the glyph whose 8x8 shape best
#            matches the real 8x8 pixel block - the net learns to guess the shape from
#            the coarse neighbourhood: edges become / \ | _ , flat areas . : = # @)
#
# Training data: photos in the repo, several scales, preprocessed like ascii_cam
# (CLAHE + autocontrast), labels by least-squares glyph matching against font_asus.bin.
# Fixed point (what brain-of-the-old-PC runs):
#   acc1 = sum(W1q[j][i] * x[i]) + b1q[j]        x 0..255, W1q int16 = round(W1*128)
#   h[j] = clamp(acc1 >> 6, 0, 4095)
#   out[k] = sum(W2q[k][j] * h[j]) + b2q[k]      W2q int16 = round(W2*64)
#   glyph = argmax out
# infer_q() mirrors the kernel exactly; nn_qemu_test.py checks them cell for cell.
import os, struct, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BM = os.path.dirname(HERE)
GLYPHS = " .:-=+*#%@/\\|_^\""          # 16 classes
NIN, NH, NOUT = 9, 32, len(GLYPHS)
FONT = os.path.join(HERE, "font_asus.bin")
WEIGHTS = os.path.join(HERE, "weights.bin")
NN_W_ADDR = 0x140000                  # where the kernel expects the blob (L-loaded)
TIER_T1, TIER_T2 = 90, 180            # centre grey -> dim / bright / white attribute


def font_masks():
    f = open(FONT, "rb").read()
    m = np.zeros((NOUT, 8, 8), dtype=np.float32)
    for k, ch in enumerate(GLYPHS):
        rows = f[ord(ch) * 8:ord(ch) * 8 + 8]
        for y, b in enumerate(rows):
            for x in range(8):
                m[k, y, x] = 1.0 if b & (0x80 >> x) else 0.0
    return m


def preprocess(gray):
    """Same look as ascii_cam: CLAHE + percentile stretch + contrast boost."""
    import cv2
    g = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(4, 4)).apply(gray).astype(np.float32)
    lo, hi = np.percentile(g, 3), np.percentile(g, 97)
    g = np.clip((g - lo) * (255.0 / max(hi - lo, 1)), 0, 255)
    g = np.clip((g - 128) * 1.6 + 128, 0, 255)
    return g


def label_blocks(blocks, masks):
    """blocks: (N,8,8) in 0..1 -> best glyph index by least squares b ~ alpha*mask."""
    N = blocks.shape[0]
    B = blocks.reshape(N, 64)
    M = masks.reshape(NOUT, 64)
    # the screen is binary ink: a glyph's lit pixels show at one colour. So match the
    # block against the raw 0/1 mask (no free brightness scale): a flat 50% block picks
    # a ~50%-dense glyph, an edge picks the glyph whose ink lies on the bright side.
    mm = (M * M).sum(1)                              # (NOUT,) = ink count
    bm = B @ M.T                                     # (N, NOUT)
    bb = (B * B).sum(1)[:, None]
    err = bb - 2 * bm + mm[None, :]
    return err.argmin(1)


def samples_from_image(gray, masks, rng, scales=(1.0, 0.6, 0.35)):
    import cv2
    X, Y = [], []
    for sc in scales:
        g = cv2.resize(gray, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA) if sc != 1.0 else gray
        g = preprocess(g)
        H, W = (g.shape[0] // 8) * 8, (g.shape[1] // 8) * 8
        if H < 24 or W < 24:
            continue
        g = g[:H, :W]
        rows, cols = H // 8, W // 8
        blocks = g.reshape(rows, 8, cols, 8).transpose(0, 2, 1, 3)          # (rows, cols, 8, 8)
        cells = blocks.mean(axis=(2, 3))                                    # (rows, cols) 0..255
        # the screen shows each cell in one of 3 colours (dim / bright / white by the cell's
        # mean, TIER_T1/T2): the glyph only has to carry the tone WITHIN its tier, so
        # normalise every block to its tier's range before matching -> all glyphs get used
        m = cells[..., None, None]
        lo = np.where(m < TIER_T1, 0.0, np.where(m < TIER_T2, TIER_T1, TIER_T2))
        hi = np.where(m < TIER_T1, TIER_T1, np.where(m < TIER_T2, TIER_T2, 255.0))
        nb = np.clip((blocks - lo) / (hi - lo), 0, 1)
        lab = label_blocks(nb.reshape(-1, 8, 8), masks).reshape(rows, cols)
        pad = np.pad(cells, 1, mode="edge")
        for r in range(rows):
            for c in range(cols):
                X.append(pad[r:r + 3, c:c + 3].reshape(9))
                Y.append(lab[r, c])
    return X, Y


def train(images, epochs=30, seed=1):
    import cv2
    rng = np.random.default_rng(seed)
    masks = font_masks()
    X, Y = [], []
    for p in images:
        buf = np.fromfile(p, dtype=np.uint8)
        bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if bgr is None:
            continue
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        for flip in (False, True):
            g = cv2.flip(gray, 1) if flip else gray
            x, y = samples_from_image(g, masks, rng)
            X += x; Y += y
    X = np.array(X, dtype=np.float32) / 255.0
    Y = np.array(Y, dtype=np.int64)
    N = len(Y)
    print("samples %d, class histogram %s" % (N, np.bincount(Y, minlength=NOUT).tolist()), flush=True)
    # class weights: soften the dominance of space / flat glyphs
    cnt = np.bincount(Y, minlength=NOUT).astype(np.float32) + 1
    cw = (cnt.sum() / cnt) ** 0.5
    cw /= cw.mean()
    W1 = rng.normal(0, 0.5, (NH, NIN)).astype(np.float32); b1 = np.zeros(NH, np.float32)
    W2 = rng.normal(0, 0.3, (NOUT, NH)).astype(np.float32); b2 = np.zeros(NOUT, np.float32)
    params = [W1, b1, W2, b2]
    m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
    lr, beta1, beta2, eps = 3e-3, 0.9, 0.999, 1e-8
    t = 0
    bs = 512
    for ep in range(epochs):
        idx = rng.permutation(N)
        tot, correct = 0.0, 0
        for s in range(0, N, bs):
            bi = idx[s:s + bs]
            x, y = X[bi], Y[bi]
            a1 = x @ W1.T + b1
            h = np.maximum(a1, 0)
            o = h @ W2.T + b2
            o -= o.max(1, keepdims=True)
            p = np.exp(o); p /= p.sum(1, keepdims=True)
            w = cw[y]
            tot += float(-(np.log(p[np.arange(len(y)), y] + 1e-9) * w).sum())
            correct += int((p.argmax(1) == y).sum())
            d = p.copy(); d[np.arange(len(y)), y] -= 1; d *= w[:, None] / len(y)
            gW2 = d.T @ h; gb2 = d.sum(0)
            dh = d @ W2; dh[a1 <= 0] = 0
            gW1 = dh.T @ x; gb1 = dh.sum(0)
            t += 1
            for k, (pp, g) in enumerate(zip(params, [gW1, gb1, gW2, gb2])):
                m[k] = beta1 * m[k] + (1 - beta1) * g
                v[k] = beta2 * v[k] + (1 - beta2) * g * g
                pp -= lr * (m[k] / (1 - beta1 ** t)) / (np.sqrt(v[k] / (1 - beta2 ** t)) + eps)
        print("epoch %2d loss %.3f acc %.3f" % (ep, tot / N, correct / N), flush=True)
    return W1, b1, W2, b2


def quantize(W1, b1, W2, b2):
    W1q = np.clip(np.round(W1 * 128), -32768, 32767).astype(np.int16)
    b1q = np.round(b1 * 128 * 255).astype(np.int32)
    W2q = np.clip(np.round(W2 * 64), -32768, 32767).astype(np.int16)
    b2q = np.round(b2 * 64 * 510).astype(np.int32)
    return W1q, b1q, W2q, b2q


def pack(W1q, b1q, W2q, b2q):
    blob = struct.pack("<4sHHH", b"NNA1", NIN, NH, NOUT)
    blob += bytes([TIER_T1, TIER_T2]) + GLYPHS.encode("latin1").ljust(16, b" ")
    blob += W1q.astype("<i2").tobytes() + b1q.astype("<i4").tobytes()
    blob += W2q.astype("<i2").tobytes() + b2q.astype("<i4").tobytes()
    return blob


def unpack(blob):
    magic, nin, nh, nout = struct.unpack_from("<4sHHH", blob, 0)
    assert magic == b"NNA1" and (nin, nh, nout) == (NIN, NH, NOUT)
    o = 10
    t1, t2 = blob[o], blob[o + 1]; o += 2
    glyphs = blob[o:o + 16].decode("latin1"); o += 16
    W1q = np.frombuffer(blob[o:o + NH * NIN * 2], dtype="<i2").reshape(NH, NIN); o += NH * NIN * 2
    b1q = np.frombuffer(blob[o:o + NH * 4], dtype="<i4"); o += NH * 4
    W2q = np.frombuffer(blob[o:o + NOUT * NH * 2], dtype="<i2").reshape(NOUT, NH); o += NOUT * NH * 2
    b2q = np.frombuffer(blob[o:o + NOUT * 4], dtype="<i4"); o += NOUT * 4
    return W1q, b1q, W2q, b2q, glyphs, t1, t2


def infer_q(cells, blob):
    """Bit-exact mirror of the kernel: cells (rows, cols) uint8 -> (chars, tiers) rows."""
    W1q, b1q, W2q, b2q, glyphs, t1, t2 = unpack(blob)
    rows, cols = cells.shape
    pad = np.pad(cells.astype(np.int64), 1, mode="edge")
    chars, tiers = [], []
    for r in range(rows):
        line, tl = [], []
        for c in range(cols):
            x = pad[r:r + 3, c:c + 3].reshape(9)
            acc1 = (W1q.astype(np.int64) * x[None, :]).sum(1) + b1q
            h = np.clip(acc1 >> 6, 0, 4095)
            out = (W2q.astype(np.int64) * h[None, :]).sum(1) + b2q
            k = int(out.argmax())
            line.append(glyphs[k])
            v = int(cells[r, c])
            tl.append(1 if v < t1 else (2 if v < t2 else 3))
        chars.append("".join(line)); tiers.append(tl)
    return chars, tiers


def main():
    imgs = [os.path.join(BM, f) for f in ("dario.jpg", "einstein.jpg", "asus_real.png", "asus_key.png")]
    extra = [a for a in sys.argv[1:] if os.path.isfile(a)]
    imgs = [p for p in imgs if os.path.isfile(p)] + extra
    t0 = time.time()
    W1, b1, W2, b2 = train(imgs, epochs=int(os.environ.get("EPOCHS", "30")))
    q = quantize(W1, b1, W2, b2)
    blob = pack(*q)
    open(WEIGHTS, "wb").write(blob)
    print("weights.bin %d B (%.0fs)" % (len(blob), time.time() - t0))
    # show the float-vs-quantized agreement on one image and print it
    import cv2
    g = cv2.cvtColor(cv2.imdecode(np.fromfile(imgs[0], dtype=np.uint8), cv2.IMREAD_COLOR), cv2.COLOR_BGR2GRAY)
    g = preprocess(cv2.resize(g, (64 * 8, 64 * 8), interpolation=cv2.INTER_AREA))
    cells = g.reshape(64, 8, 64, 8).mean(axis=(1, 3)).astype(np.uint8)
    chars, _ = infer_q(cells, blob)
    for ln in chars:
        print(ln)


if __name__ == "__main__":
    main()
