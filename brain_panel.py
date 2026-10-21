#!/usr/bin/env python3
# brain_panel.py - the C. elegans brain, computed by the OLD PC's CPU, drawn as live
# ASCII on its screen next to your face (ascii_cam --layout brain).
#
# The face/chat kernel carries the 302-neuron LIF brain (brain.asm, UDP 'n' command).
# Per video frame this PC: turns what the camera sees into sensory input (head touch
# when you move, chemo when you lean in/out) -> L-loads the EXT vector -> nS<k> runs k
# steps at ring 0 -> reads back v[] + spike bitmap -> paints it in several forms:
#   NETWORK  nodes in three layer columns (sensory / inter / motor); a neuron that fired
#            is a white '@' and its strongest synapses are drawn as ASCII wires to the
#            targets ('-' '/' '\' '|'), bright this step, dim the step after
#   RASTER   spike raster: time runs left -> right, one row per group of neurons
#   TREND    spikes-per-step bar chart over the last frames, forward / backward drive
# Nothing here is simulated on the dev PC: v[] and spikes come from the old PC.
import os
import socket
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "worm"))
sys.path.insert(0, os.path.join(HERE, "organism"))

BR_BLOB, BR_EXT = 0x100000, 0x105000


def _line_cells(r0, c0, r1, c1):
    """Bresenham cells strictly between two nodes, with a slope glyph each."""
    dr, dc = r1 - r0, c1 - c0
    n = max(abs(dr), abs(dc))
    if n <= 1:
        return []
    if abs(dc) >= 2 * abs(dr):
        g = "-"
    elif abs(dr) >= 2 * abs(dc):
        g = "|"
    else:
        g = "\\" if (dr > 0) == (dc > 0) else "/"
    out = []
    for k in range(1, n):
        out.append((r0 + round(dr * k / n), c0 + round(dc * k / n), g))
    return out


class BrainPanel:
    def __init__(self, ip, port, steps_per_frame=10, timeout=0.25, panel_w=62, panel_h=96,
                 raster_w=64, raster_h=28, history=64):
        from wormsim import Brain
        from hw import HW
        self.b = Brain()
        self.hw = HW(ip, port=port, timeout=timeout)
        self.hw.timeout = timeout
        self.steps = steps_per_frame
        self.NR, self.n = self.b.NR, self.b.nneurons
        self.sens_end, self.inter_end = self.b.sens_end, self.b.inter_end
        self.W, self.H = panel_w, panel_h
        self.RW, self.RH = raster_w, max(1, raster_h)
        # outgoing synapses (target, |w|) sorted strongest first; the wires we draw
        self.out = [sorted([(d, abs(w)) for d, w in lst if d < self.n], key=lambda t: -t[1])
                    for lst in self.b.csr[:self.n]]
        self.targets = [np.array([d for d, w in o], dtype=np.int32) for o in self.out]
        self.v = np.zeros(self.NR, dtype=np.int16)
        self.spk = np.zeros(self.NR, dtype=bool)
        self.gi = 0
        self.step_count = 0
        self.ready = False
        self.lost = 0
        self.stim_state = {"touch_head": 0, "touch_tail": 0, "chemo_up": 0, "chemo_down": 0}
        self.hist_fired = []                        # per frame: total fired
        self.hist_fwd, self.hist_bwd = [], []
        self.history = history
        self.raster = np.zeros((self.RH, raster_w), dtype=np.int16)   # group x time
        self.prev_wires = []
        self._layout()

    # ---- the old PC side -------------------------------------------------------
    def connect(self):
        """Load the connectome blob into the old PC's RAM and expand it (nI)."""
        blob = self.b.blob
        for attempt in range(3):
            self.hw.load(BR_BLOB, blob, chunk=512, verify=True)
            r = self._ask(b"nI", 4, tries=3)
            if r and r[:2] == b"nI":
                nsyn = int.from_bytes(r[2:4], "little")
                self._ask(b"nM0", 2, tries=2)             # SSE2 dense path
                self.ready = nsyn == self.b.nsyn
                print("brain on the old PC: %d synapses expanded (blob %d B)%s" % (
                    nsyn, len(blob), "" if self.ready else "  MISMATCH"), flush=True)
                if self.ready:
                    return True
            time.sleep(0.3)
        print("brain: old PC did not answer nI", flush=True)
        return False

    def _ask(self, cmd, need, tries=2):
        """Send cmd, return the first reply of exactly `need` bytes (short L acks and
        stale datagrams are skipped), or None after `tries` timeouts."""
        sock = self.hw.s
        for _ in range(tries):
            sock.sendto(cmd, (self.hw.ip, self.hw.port))
            deadline = time.time() + self.hw.timeout
            while time.time() < deadline:
                sock.settimeout(max(0.001, deadline - time.time()))
                try:
                    d, _ = sock.recvfrom(4096)
                except (socket.timeout, ConnectionResetError, OSError):
                    break
                if len(d) == need:
                    return d
        return None

    def stimulus(self, motion, approach):
        """Camera -> sensory input. motion: 0..1 (how much the face moved);
        approach: >0 leaning in, <0 leaning back (box height change)."""
        e = self.b.bias_ext()
        st = self.b.stim
        def add(slot, val):
            e[st[slot]] = np.int16(min(32767, int(e[st[slot]]) + val))
        s = self.stim_state
        s["touch_head"] = 1 if motion > 0.12 else 0
        s["touch_tail"] = 1 if motion > 0.35 else 0        # a big jolt hits the tail cells too
        s["chemo_up"] = 1 if approach > 0.02 else 0
        s["chemo_down"] = 1 if approach < -0.02 else 0
        if s["touch_head"]:
            add(0, 300); add(1, 300); add(2, 300)          # ALML ALMR AVM
        if s["touch_tail"]:
            add(3, 300); add(4, 300)                       # PLML PLMR
        if s["chemo_up"]:
            add(5, 150)                                    # ASEL (food getting closer)
        if s["chemo_down"]:
            add(6, 150); add(7, 100); add(8, 100)          # ASER AWCL AWCR
        if self.step_count % 13 == 0:
            add(11, 50)                                    # a little ASH noise, as the env does
        return e

    def tick(self, motion=0.0, approach=0.0):
        """One video frame: push the stimulus, run k steps on the old PC, read back."""
        if not self.ready:
            return False
        e = self.stimulus(motion, approach)
        pkt = ("L%08X" % BR_EXT).encode() + e.astype("<i2").tobytes()   # 800 B, one packet
        for _ in range(2):                                 # fire-and-forget x2: the L ack drops
            self.hw.s.sendto(pkt, (self.hw.ip, self.hw.port))   # often on real metal, the write lands
        need = self.NR * 2 + self.NR // 8 + 2
        r = self._ask(b"nS%04X" % self.steps, need)        # (the L acks arrive in between: skip them)
        if r is None:
            self.lost += 1
            return False
        self.v = np.frombuffer(r[:self.NR * 2], dtype="<i2")
        bits = np.unpackbits(np.frombuffer(r[self.NR * 2:self.NR * 2 + self.NR // 8], dtype=np.uint8),
                             bitorder="little")
        self.spk = bits[:self.NR].astype(bool)
        self.gi = int.from_bytes(r[-2:], "little", signed=True)
        self.step_count += self.steps
        # history for the trend / raster forms
        f = int(self.spk[:self.n].sum())
        self.hist_fired.append(f)
        self.hist_fwd.append(int(self.spk[self.b.fwd[0]:self.b.fwd[1]].sum()))
        self.hist_bwd.append(int(self.spk[self.b.bwd[0]:self.b.bwd[1]].sum()))
        for h in (self.hist_fired, self.hist_fwd, self.hist_bwd):
            del h[:-self.history]
        per = -(-self.n // self.RH)
        col = np.zeros(self.RH, dtype=np.int16)
        for g in range(self.RH):
            col[g] = int(self.spk[g * per:min(self.n, (g + 1) * per)].sum())
        self.raster = np.roll(self.raster, -1, axis=1)
        self.raster[:, -1] = col
        return True

    # ---- layout --------------------------------------------------------------------
    def _layout(self):
        """Neuron -> (row, col) in the panel: three layer columns far apart so the wires
        between them have room. sensory 2 cols | inter 3 cols | motor 3 cols."""
        big = self.H >= 90
        top, h = (4, 52) if big else (3, 44)
        xs = (1, 27, 54) if big else (1, 15, 29)
        groups = [(0, self.sens_end, 2, xs[0]), (self.sens_end, self.inter_end, 3, xs[1]),
                  (self.inter_end, self.n, 3, xs[2])]
        self.pos = {}
        self.group_x = []
        for g0, g1, ncol, x0 in groups:
            per = -(-(g1 - g0) // ncol)
            for i in range(g0, g1):
                k = i - g0
                r = top + round(k % per * (h - 1) / max(per - 1, 1))
                self.pos[i] = (r, x0 + 2 * (k // per))
            self.group_x.append((x0, x0 + 2 * ncol - 1))
        self.nodes_end = top + h
        self.xs = xs

    @staticmethod
    def _cell(v):
        if v < -16:
            return ".", 1
        if v < 16:
            return ":", 1
        if v < 32:
            return "+", 2
        if v < 48:
            return "*", 2
        return "#", 2

    def render(self):
        """-> (lines, tiers): H rows x W cols for the right panel."""
        W, H = self.W, self.H
        ch = [[" "] * W for _ in range(H)]
        tr = [[1] * W for _ in range(H)]
        def put(r, c, text, tier):
            for i, x in enumerate(text):
                if 0 <= c + i < W and 0 <= r < H:
                    ch[r][c + i] = x; tr[r][c + i] = tier
        fired = int(self.spk[:self.n].sum())
        put(0, 0, "C.ELEGANS 302 NEURONS - COMPUTED AT RING 0 ON THIS CPU"[:W], 3)
        put(1, 0, "step %06d  fired %3d  gi %5d  %d steps/frame" % (self.step_count, fired, self.gi, self.steps), 2)
        lab_row = 3 if self.H >= 90 else 2
        put(lab_row, self.xs[0], "SENSORY", 2); put(lab_row, self.xs[1], "INTER", 2); put(lab_row, self.xs[2], "MOTOR", 2)
        # wires: last step's dim, this step's bright (strongest 4 synapses of each spike)
        wires = []
        for i in np.nonzero(self.spk[:self.n])[0]:
            r0, c0 = self.pos[i]
            for d, w in self.out[i][:4]:
                if w < 8:
                    break
                r1, c1 = self.pos[d]
                wires.append((r0, c0, r1, c1))
        for (r0, c0, r1, c1) in self.prev_wires:
            for r, c, g in _line_cells(r0, c0, r1, c1):
                if 0 <= r < H and 0 <= c < W and ch[r][c] == " ":
                    ch[r][c], tr[r][c] = g, 1
        for (r0, c0, r1, c1) in wires:
            for r, c, g in _line_cells(r0, c0, r1, c1):
                if 0 <= r < H and 0 <= c < W and ch[r][c] in " .-|/\\":
                    ch[r][c], tr[r][c] = g, 2
        self.prev_wires = wires
        # nodes on top of the wires
        hit = np.zeros(self.NR, dtype=bool)
        for i in np.nonzero(self.spk[:self.n])[0]:
            hit[self.targets[i][:4]] = True
        for i in range(self.n):
            r, c = self.pos[i]
            if self.spk[i]:
                ch[r][c], tr[r][c] = "@", 3
            elif hit[i]:
                ch[r][c], tr[r][c] = "+", 3
            else:
                ch[r][c], tr[r][c] = self._cell(int(self.v[i]))
        if self.H < 90:                                # small screen: no room for the rest
            return ["".join(r) for r in ch], tr
        # trend: spikes per step over the last frames (bar chart), fwd / bwd drive
        y0 = self.nodes_end + 2
        put(y0, 0, "ACTIVITY (spikes/step, last %d frames)" % self.history, 2)
        bars_h = 10
        hist = self.hist_fired[-W:]
        top = max(hist + [1])
        for k, f in enumerate(hist):
            hgt = round(f / top * bars_h)
            for j in range(hgt):
                r = y0 + 1 + bars_h - 1 - j
                hi = j >= bars_h * 2 // 3
                ch[r][k], tr[r][k] = ("#" if hi else "+"), (3 if hi else 2)
        put(y0 + 1 + bars_h, 0, "fwd pool " + "".join("#" if x else "." for x in self.hist_fwd[-(W - 9):]), 2)
        put(y0 + 2 + bars_h, 0, "bwd pool " + "".join("#" if x else "." for x in self.hist_bwd[-(W - 9):]), 2)
        # inputs from the camera, outputs, stats
        s = self.stim_state
        y = y0 + 4 + bars_h
        put(y, 0, "IN (camera -> sensory neurons)", 2)
        put(y + 1, 2, "touch head ALM/AVM", 3 if s["touch_head"] else 1)
        put(y + 2, 2, "touch tail PLM", 3 if s["touch_tail"] else 1)
        put(y + 3, 2, "food closer ASEL", 3 if s["chemo_up"] else 1)
        put(y + 4, 2, "food farther ASER/AWC", 3 if s["chemo_down"] else 1)
        fwd, bwd = (self.hist_fwd or [0])[-1], (self.hist_bwd or [0])[-1]
        put(y, 32, "OUT (motor pools)", 2)
        put(y + 1, 34, "forward  " + "#" * min(fwd, 12), 2)
        put(y + 2, 34, "backward " + "#" * min(bwd, 12), 2)
        put(y + 3, 34, "active %3d  lost %d" % (int((self.v[:self.n] > 16).sum()), self.lost), 1)
        put(y + 4, 34, "Asus K50IJ T4300, no OS", 1)
        return ["".join(r) for r in ch], tr

    def render_raster(self):
        """-> (lines, tiers): RH rows x RW cols spike raster (time -> right)."""
        lines, tiers = [], []
        glyph = " .:+*#"
        for g in range(self.RH):
            row, tr = [], []
            for t in range(self.RW):
                k = min(int(self.raster[g, t]), 5)
                row.append(glyph[k]); tr.append(1 if k < 2 else (2 if k < 4 else 3))
            lines.append("".join(row)); tiers.append(tr)
        return lines, tiers
