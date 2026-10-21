#!/usr/bin/env python3
# brain_panel.py - the C. elegans brain, computed by the OLD PC's CPU, drawn as a live
# ASCII network on the right half of its screen (ascii_cam --layout brain).
#
# The face/chat kernel carries the 302-neuron LIF brain (brain.asm, UDP 'n' command).
# Per video frame this PC: turns what the camera sees into sensory input (head touch
# when you move, chemo when you lean in/out) -> L-loads the EXT vector -> nS<k> runs k
# steps at ring 0 -> reads back v[] + spike bitmap -> paints the neurons:
#   ' ' . :  (below rest / rising, dim green)   + * #  (near threshold, bright green)
#   @ white = fired this step;  '+' flash on the targets of neurons that fired
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
PANEL_COL0 = 40                                  # right half of the 80-col screen
PANEL_W, PANEL_H = 40, 48


class BrainPanel:
    def __init__(self, ip, port, steps_per_frame=10, timeout=0.25):
        from wormsim import Brain
        from hw import HW
        self.b = Brain()
        self.hw = HW(ip, port=port, timeout=timeout)
        self.hw.timeout = timeout
        self.steps = steps_per_frame
        self.NR, self.n = self.b.NR, self.b.nneurons
        self.sens_end, self.inter_end = self.b.sens_end, self.b.inter_end
        # postsynaptic targets of every neuron (for the "signal arrives" flash)
        self.targets = [np.array([d for d, w in lst if d < self.n], dtype=np.int32)
                        for lst in self.b.csr[:self.n]]
        self.v = np.zeros(self.NR, dtype=np.int16)
        self.spk = np.zeros(self.NR, dtype=bool)
        self.gi = 0
        self.step_count = 0
        self.ready = False
        self.lost = 0
        self.stim_state = {"touch_head": 0, "touch_tail": 0, "chemo_up": 0, "chemo_down": 0}
        self._layout()

    # ---- the old PC side -------------------------------------------------------
    def connect(self):
        """Load the connectome blob into the old PC's RAM and expand it (nI)."""
        blob = self.b.blob
        for attempt in range(3):
            ok = self.hw.load(BR_BLOB, blob, chunk=512, verify=True)
            r = self.hw._raw(b"nI")
            if r and r[:2] == b"nI":
                nsyn = int.from_bytes(r[2:4], "little")
                self.hw._raw(b"nM0")                  # SSE2 dense path
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
        return True

    # ---- the picture -------------------------------------------------------------
    def _layout(self):
        """Neuron -> (row, col) inside the panel: sensory 2 columns, inter 3, motor 3."""
        self.pos = {}
        groups = [(0, self.sens_end, 2, 1), (self.sens_end, self.inter_end, 3, 10),
                  (self.inter_end, self.n, 3, 20)]
        self.group_x = []
        for g0, g1, ncol, x0 in groups:
            per = -(-(g1 - g0) // ncol)
            for i in range(g0, g1):
                k = i - g0
                self.pos[i] = (3 + k % per, x0 + 2 * (k // per))
            self.group_x.append((x0, x0 + 2 * ncol - 1))

    @staticmethod
    def _cell(v, fired):
        if fired:
            return "@", 3
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
        """-> (lines, tiers) for PANEL_H rows x PANEL_W cols."""
        ch = [[" "] * PANEL_W for _ in range(PANEL_H)]
        tr = [[1] * PANEL_W for _ in range(PANEL_H)]
        def put(r, c, text, tier):
            for i, x in enumerate(text):
                if 0 <= c + i < PANEL_W and 0 <= r < PANEL_H:
                    ch[r][c + i] = x; tr[r][c + i] = tier
        fired = int(self.spk[:self.n].sum())
        put(0, 0, "C.ELEGANS 302 NEURONS @ RING 0", 3)
        put(1, 0, "step %06d fired %3d gi %5d" % (self.step_count, fired, self.gi), 2)
        put(2, 1, "SENSORY", 2); put(2, 10, "INTER", 2); put(2, 20, "MOTOR", 2)
        # targets of this step's spikes flash '+' (the signal arriving)
        hit = np.zeros(self.NR, dtype=bool)
        for i in np.nonzero(self.spk[:self.n])[0]:
            hit[self.targets[i]] = True
        for i in range(self.n):
            r, c = self.pos[i]
            if self.spk[i]:
                ch[r][c], tr[r][c] = "@", 3
            elif hit[i]:
                ch[r][c], tr[r][c] = "+", 3
            else:
                ch[r][c], tr[r][c] = self._cell(int(self.v[i]), False)
        # between the groups: a dim '-' on rows where a spike crosses to the right
        for (x0, x1), (nx0, _) in zip(self.group_x[:-1], self.group_x[1:]):
            rows = set()
            for i in np.nonzero(self.spk[:self.n])[0]:
                r, c = self.pos[i]
                if x0 <= c <= x1 and len(self.targets[i]):
                    rows.add(r)
            for r in rows:
                for c in range(x1 + 1, nx0):
                    ch[r][c], tr[r][c] = "-", 2
        # right strip: inputs from the camera, outputs = motor pools
        s = self.stim_state
        put(3, 28, "IN (camera)", 2)
        put(4, 28, "touch head", 3 if s["touch_head"] else 1)
        put(5, 28, "touch tail", 3 if s["touch_tail"] else 1)
        put(6, 28, "food +", 3 if s["chemo_up"] else 1)
        put(7, 28, "food -", 3 if s["chemo_down"] else 1)
        put(9, 28, "OUT (motor)", 2)
        fwd = int(self.spk[self.b.fwd[0]:self.b.fwd[1]].sum())
        bwd = int(self.spk[self.b.bwd[0]:self.b.bwd[1]].sum())
        put(10, 28, "fwd " + "#" * min(fwd, 7), 2)
        put(11, 28, "bwd " + "#" * min(bwd, 7), 2)
        act = int((self.v[:self.n] > 16).sum())
        put(13, 28, "active %3d" % act, 2)
        put(14, 28, "lost  %4d" % self.lost, 1)
        put(16, 28, "CPU: T4300", 1)
        put(17, 28, "no OS, SSE2", 1)
        return ["".join(r) for r in ch], tr
