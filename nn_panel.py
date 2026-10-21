#!/usr/bin/env python3
# nn_panel.py - "show the model computing": a side panel for ascii_cam --layout nn.
# Every frame the old PC renders the picture with its own MLP (kernel 'i' command); one
# cell per frame is the PROBE: the kernel snapshots that cell's input x[9], hidden h[32],
# output scores out[16] and argmax into NN_TRACE, this PC reads them back with 'y' (no
# console echo) and draws them: input patch, hidden bars, output bars (winner white),
# and the weight matrices W1 / W2 as sign/magnitude maps. The probe sweeps the picture.
import os
import socket
import struct
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "nnascii"))

NN_PROBE, NN_TRACE = 0x1540D0, 0x154200
TRACE_LEN = 0x140


class NNPanel:
    def __init__(self, sock, ip, port, width=36, height=96, pic_rows=90, pic_cols=90):
        import nnascii
        self.sock, self.ip, self.port = sock, ip, port
        self.W, self.H = width, height
        self.pic_rows, self.pic_cols = pic_rows, pic_cols
        self.blob = open(nnascii.WEIGHTS, "rb").read()
        self.W1q, self.b1q, self.W2q, self.b2q, self.glyphs, self.t1, self.t2 = nnascii.unpack(self.blob)
        self.probe = (pic_rows // 2, pic_cols // 2)
        self.n = 0
        self.trace = None
        self.lost = 0
        self.hist = []                                   # hidden activations of recent probes

    # ---- the old PC side ------------------------------------------------------------
    def set_probe(self):
        """Pick the next probe cell (sweeps across the picture) and tell the kernel."""
        r, c = self.probe
        c += 7
        if c >= self.pic_cols:
            c -= self.pic_cols
            r = (r + 5) % self.pic_rows
        self.probe = (r, c)
        pkt = ("L%08X" % NN_PROBE).encode() + struct.pack("<II", r, c)
        for _ in range(2):
            self.sock.sendto(pkt, (self.ip, self.port))

    def read_trace(self, tries=2):
        for _ in range(tries):
            self.sock.sendto(b"y%08X%04X" % (NN_TRACE, TRACE_LEN), (self.ip, self.port))
            deadline = time.time() + 0.15
            while time.time() < deadline:
                self.sock.settimeout(max(0.001, deadline - time.time()))
                try:
                    d, _ = self.sock.recvfrom(2048)
                except (socket.timeout, ConnectionResetError, OSError):
                    break
                if len(d) == TRACE_LEN:
                    x = np.frombuffer(d[0:36], dtype="<i4")
                    h = np.frombuffer(d[0x40:0x40 + 128], dtype="<i4")
                    best = struct.unpack_from("<iI", d, 0xC0)
                    pr = struct.unpack_from("<II", d, 0xD0)
                    out = np.frombuffer(d[0x100:0x100 + 64], dtype="<i4")
                    self.trace = (x, h, best, pr, out)
                    return True
        self.lost += 1
        return False

    # ---- the panel --------------------------------------------------------------------
    def render(self, fps=0.0):
        W, H = self.W, self.H
        ch = [[" "] * W for _ in range(H)]
        tr = [[1] * W for _ in range(H)]
        def put(r, c, text, tier):
            for i, x in enumerate(str(text)):
                if 0 <= c + i < W and 0 <= r < H:
                    ch[r][c + i] = x; tr[r][c + i] = tier
        put(0, 0, "NEURAL NET @ RING 0", 3)
        put(1, 0, "9 -> 32 -> 16 MLP, int16/int32", 2)
        put(2, 0, "%d cells x 800 MAC per frame" % (self.pic_rows * self.pic_cols), 1)
        if self.trace is None:
            put(4, 0, "waiting for the trace...", 1)
            return ["".join(r) for r in ch], tr
        x, h, (bestv, bestk), (pr, pc), out = self.trace
        k = int(bestk) if 0 <= bestk < len(self.glyphs) else 0
        put(4, 0, "probe cell r%02d c%02d -> '%s'" % (pr, pc, self.glyphs[k]), 3)
        put(6, 0, "INPUT  3x3 grey (0-255)", 2)
        for i in range(3):
            put(7 + i, 2, " ".join("%3d" % x[i * 3 + j] for j in range(3)), 3 if i == 1 else 2)
        put(11, 0, "HIDDEN  relu((W1.x+b1)>>6)", 2)
        for j in range(16):
            for col, jj in ((0, j), (18, j + 16)):
                bar = int(h[jj]) * 14 // 4095
                put(12 + j, col, "%2d" % jj, 1)
                put(12 + j, col + 3, "#" * bar, 2 if bar < 11 else 3)
        put(29, 0, "OUTPUT  W2.h+b2  (argmax = glyph)", 2)
        lo, hi = int(out.min()), int(out.max())
        for kk in range(16):
            bar = int((int(out[kk]) - lo) * 30 / max(hi - lo, 1))
            g = self.glyphs[kk] if kk < len(self.glyphs) else "?"
            put(30 + kk, 0, g, 3 if kk == k else 2)
            put(30 + kk, 2, ("#" if kk == k else "+") * bar, 3 if kk == k else 1)
        put(47, 0, "W1  32 hidden x 9 inputs", 2)
        self._matrix(put, 48, self.W1q.T, 8.0)            # 9 rows x 32 cols
        put(58, 0, "W2  16 glyphs x 32 hidden", 2)
        self._matrix(put, 59, self.W2q, 4.0)              # 16 rows x 32 cols
        # live multiply-accumulate of ONE hidden unit (a different one every frame): the
        # exact integers the old PC just multiplied, the running sum, the shift and clamp,
        # checked against the h[j] it reported
        j = self.n % 32
        w = self.W1q[j]
        prods = [int(x[i]) * int(w[i]) for i in range(9)]
        acc = sum(prods) + int(self.b1q[j])
        hj = max(0, min(4095, acc >> 6))
        put(76, 0, "MAC TRACE  hidden unit %2d" % j, 3)
        run = 0
        for i in range(9):
            run += prods[i]
            put(77 + i, 0, "x%d %3d*w%+4d=%+7d sum %+8d" % (i, int(x[i]), int(w[i]), prods[i], run), 2 if i == 4 else 1)
        put(86, 0, "+b %+7d -> %+8d >>6 clamp" % (int(self.b1q[j]), acc), 2)
        put(87, 0, "= h[%2d] %4d  %s" % (j, hj, "old PC says %4d OK" % int(h[j]) if hj == int(h[j]) else "MISMATCH %d" % int(h[j])),
            3 if hj == int(h[j]) else 2)
        put(87, 20 + 0, "", 1)
        # hidden-layer activity over the last frames: 32 columns = hidden units, newest row last
        self.hist.append(np.array(h[:32]))
        del self.hist[:-6]
        put(88, 0, "h[0..31] last %d frames:" % len(self.hist), 2)
        glyph = " .:+*#"
        for r, hv in enumerate(self.hist):
            line = "".join(glyph[min(5, int(v) * 6 // 4096)] for v in hv)
            for c, g in enumerate(line):
                put(89 + r, c, g, 3 if g == "#" else (2 if g in "+*" else 1))
        put(89 + len(self.hist), 0, "frame %d %.1f fps lost %d  no OS" % (self.n, fps, self.lost), 1)
        return ["".join(r) for r in ch], tr

    @staticmethod
    def _matrix(put, r0, M, scale):
        for i in range(M.shape[0]):
            line, tiers = [], []
            for j in range(M.shape[1]):
                v = float(M[i, j]) / scale
                a = abs(v)
                if a < 1:
                    g, t = ".", 1
                elif a < 3:
                    g, t = ("+" if v > 0 else "-"), 1
                elif a < 8:
                    g, t = ("+" if v > 0 else "-"), 2
                else:
                    g, t = ("#" if v > 0 else "="), 3
                line.append(g); tiers.append(t)
            for j, (g, t) in enumerate(zip(line, tiers)):
                put(r0 + i, j, g, t)
