#!/usr/bin/env python3
"""wormsim.py - bit-exact Python reference of the kernel's brain step (brain.asm)
plus a quick behaviour sandbox (touch -> reversal / forward, chemotaxis).

The Brain class mirrors the kernel EXACTLY (int16 saturation, int32 wrap,
arithmetic shifts, per-row thresholds) so a test can load the same brain.bin into
the old PC, run N steps there and compare v/s with this reference (maxdiff = 0).
"""
import json, os, struct, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")


def sat16(x):
    return np.clip(x, -32768, 32767).astype(np.int16)


def wrap32(x):
    return ((np.asarray(x, dtype=np.int64) + (1 << 31)) % (1 << 32) - (1 << 31)).astype(np.int32)


class Brain:
    def __init__(self, blob=None):
        if blob is None:
            with open(os.path.join(DATA, "brain.bin"), "rb") as f:
                blob = f.read()
        self.blob = blob
        h = blob[:128]
        (magic, self.NR, self.NC, self.nneurons, self.nmuscle, self.nsyn,
         self.ncontacts) = struct.unpack_from("<4sHHHHHH", h, 0)
        assert magic == b"WRM1"
        (self.leak_shift, self.w_shift, self.reset, self.vmin, self.spike,
         self.steps_per_frame) = struct.unpack_from("<HHhhhH", h, 16)
        self.fwd = struct.unpack_from("<HH", h, 28)
        self.bwd = struct.unpack_from("<HH", h, 32)
        self.sens_end, self.inter_end, self.motor_end, self.muscle_row0 = struct.unpack_from("<HHHH", h, 36)
        thr_s, thr_i, thr_m, thr_mu = struct.unpack_from("<hhhh", h, 44)
        nbias = struct.unpack_from("<H", h, 52)[0]
        (self.adapt_shift, _unused, self.gi_gain, self.gi_shift,
         self.gi_max) = struct.unpack_from("<HhHHh", h, 54)
        ainc_s, ainc_i, ainc_m = struct.unpack_from("<hhh", h, 120)
        self.bias = [struct.unpack_from("<Hh", h, 96 + 4 * k) for k in range(nbias)]
        self.stim = list(struct.unpack_from("<16H", h, 64))
        offs = struct.unpack_from("<%dH" % (self.NC + 1), blob, 128)
        ent = struct.unpack_from("<%dH" % self.nsyn, blob, 128 + 612)
        # dense W[row][col], int16 (kernel brain_init expands the same way, += per entry)
        W = np.zeros((self.NR, self.NC), dtype=np.int32)
        self.csr = []
        for j in range(self.NC):
            lst = []
            for e in ent[offs[j]:offs[j + 1]]:
                dst = e & 0x1FF
                w = e >> 9
                if w & 0x40:
                    w -= 0x80
                W[dst, j] += w
                lst.append((dst, w))
            self.csr.append(lst)
        self.W = sat16(W)
        thr = np.zeros(self.NR, dtype=np.int16)
        thr[:self.sens_end] = thr_s
        thr[self.sens_end:self.inter_end] = thr_i
        thr[self.inter_end:self.motor_end] = thr_m
        thr[self.motor_end:self.muscle_row0] = thr_mu       # pad rows never fire
        thr[self.muscle_row0:] = thr_mu
        self.thr = thr
        ainc = np.zeros(self.NR, dtype=np.int16)        # per-row adaptation increment
        ainc[:self.sens_end] = ainc_s
        ainc[self.sens_end:self.inter_end] = ainc_i
        ainc[self.inter_end:self.motor_end] = ainc_m
        self.ainc = ainc
        self.reset_state()

    def reset_state(self):
        self.v = np.zeros(self.NR, dtype=np.int16)
        self.s = np.zeros(self.NR, dtype=np.int16)
        self.ext = np.zeros(self.NR, dtype=np.int16)
        self.a = np.zeros(self.NR, dtype=np.int16)       # spike-frequency adaptation
        self.gi = 0                                       # global inhibition (from last step's spikes)
        self.step_no = 0

    def bias_ext(self):
        """ext = tonic bias (what the worm environment does every frame)."""
        e = np.zeros(self.NR, dtype=np.int16)
        for i, b in self.bias:
            e[i] = b
        return e

    def step(self, sparse=False):
        """One brain step. Mirrors brain.asm bit for bit."""
        s = self.s[:self.NC].astype(np.int64)
        if sparse:
            acc = np.zeros(self.NR, dtype=np.int64)
            for j in range(self.NC):
                if s[j]:
                    for dst, w in self.csr[j]:
                        acc[dst] += w * s[j]
            acc = wrap32(acc)
        else:
            acc = wrap32(self.W.astype(np.int64) @ s)
        inp = sat16(acc.astype(np.int64) >> self.w_shift)              # psrad + packssdw
        inp = sat16(inp.astype(np.int64) + self.ext.astype(np.int64))  # paddsw
        inp = sat16(inp.astype(np.int64) - self.a.astype(np.int64))    # psubsw (adaptation)
        gi = np.zeros(self.NR, dtype=np.int64); gi[:self.NC] = self.gi  # neurons only, not muscles
        inp = sat16(inp.astype(np.int64) - gi)                           # psubsw (global inhibition)
        v = self.v.astype(np.int64)
        v = v - (v >> self.leak_shift)                                   # psraw + psubsw (no overflow)
        v = sat16(v + inp)                                               # paddsw
        v = np.maximum(v, np.int16(self.vmin)).astype(np.int16)         # pmaxsw
        fire = v >= self.thr                                             # pcmpgtw(v, thr-1)
        self.s = np.where(fire, np.int16(self.spike), np.int16(0)).astype(np.int16)
        self.v = np.where(fire, np.int16(self.reset), v).astype(np.int16)
        a = self.a.astype(np.int64)
        a = a - (a >> self.adapt_shift)
        self.a = sat16(a + np.where(fire, self.ainc.astype(np.int64), 0))
        total = int(self.s[:self.NC].astype(np.int64).sum())            # spikes this step
        self.gi = int(min(max((total * self.gi_gain) >> self.gi_shift, -32768), self.gi_max))
        self.step_no += 1

    # ---- readouts used by the body model (and the kernel) ----
    def fwd_drive(self):
        return int(self.s[self.fwd[0]:self.fwd[1]].sum())

    def bwd_drive(self):
        return int(self.s[self.bwd[0]:self.bwd[1]].sum())

    def muscles(self):
        m = self.v[self.muscle_row0:self.muscle_row0 + self.nmuscle].astype(np.int32)
        return m[0:24], m[24:48], m[48:72], m[72:96]      # DL, DR, VL, VR

    def head_lr(self):
        """left - right activation of the first 8 muscle rows (steering in the top view)."""
        dl, dr, vl, vr = self.muscles()
        return int(dl[:8].sum() + vl[:8].sum() - dr[:8].sum() - vr[:8].sum())

    def head_bend(self):
        """dorsal - ventral activation of the first 8 muscle rows (steering)."""
        dl, dr, vl, vr = self.muscles()
        return int(dl[:8].sum() + dr[:8].sum() - vl[:8].sum() - vr[:8].sum())


def names():
    with open(os.path.join(DATA, "brain.json")) as f:
        return json.load(f)["names"]


# ------------------------- behaviour sandbox -------------------------
def run(stim, steps=240, brain=None, log=False):
    """stim(brain, t) -> list of (slot_index, value) or None. Returns per-step
    (fwd, bwd, head_bend)."""
    b = brain or Brain()
    out = []
    for t in range(steps):
        e = b.bias_ext()
        for slot, val in (stim(b, t) or []):
            e[b.stim[slot]] = sat16(np.int32(e[b.stim[slot]]) + val)
        b.ext = e
        b.step()
        out.append((b.fwd_drive(), b.bwd_drive(), b.head_bend()))
        if log and t % 10 == 0:
            print(t, out[-1], "fired", int(b.s[:302].sum()))
    return out


def summary(label, out, t0, t1):
    f = sum(o[0] for o in out[t0:t1]); bk = sum(o[1] for o in out[t0:t1])
    hb = sum(o[2] for o in out[t0:t1]) / max(1, t1 - t0)
    print("%-28s fwd %5d  bwd %5d  headbend %8.0f" % (label, f, bk, hb))
    return f, bk


if __name__ == "__main__":
    b = Brain()
    print("NR %d NC %d nsyn %d contacts %d fwd %s bwd %s" % (b.NR, b.NC, b.nsyn, b.ncontacts, b.fwd, b.bwd))
    base = run(lambda b, t: None, 300)
    summary("no stimulus 0-100", base, 0, 100)
    summary("no stimulus 200-300", base, 200, 300)
    head = run(lambda b, t: [(0, 300), (1, 300), (2, 300)] if 100 <= t < 130 else None, 300)
    summary("head touch (t100-130) 100-160", head, 100, 160)
    tail = run(lambda b, t: [(3, 300), (4, 300)] if 100 <= t < 130 else None, 300)
    summary("tail touch (t100-130) 100-160", tail, 100, 160)
    aser = run(lambda b, t: [(6, 200)] if 100 <= t < 160 else None, 300)
    summary("ASER (food decreasing)", aser, 100, 160)
    asel = run(lambda b, t: [(5, 200)] if 100 <= t < 160 else None, 300)
    summary("ASEL (food increasing)", asel, 100, 160)
