#!/usr/bin/env python3
"""wormenv.py - the petri-dish body/environment model, integer arithmetic only,
written to be ported line by line into worm.asm (the kernel). The brain part is
the bit-exact wormsim.Brain; the body part is a kinematic cartoon:

  * body = NSEG points, SEG px apart ("follow the leader" chain)
  * forward: the head is the leader; it moves `speed` px/frame along the heading,
    swinging left/right with a sine -> the classic travelling body wave
  * backward: the tail is the leader (the chain reverses)
  * speed/direction from the brain: B-class (fwd) vs A-class (bwd) motor spikes
  * steering from the brain: dorsal vs ventral activation of the head muscles
  * chemotaxis input: concentration at the head, its change -> ASEL (up) / ASER (down)
  * touch input: keys / dish wall -> ALM+AVM (head) or PLM (tail)

Run `python wormenv.py` for a closed-loop text test (reversal on head touch,
forward on tail touch, approach food).
"""
import math, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wormsim import Brain, sat16

NSEG = 24
SEG = 9                 # px between body points
W, H = 1024, 768
DISH_CX, DISH_CY, DISH_R = 400, 400, 340      # petri dish (the right side holds the raster)
FOOD_R = 180            # food glow radius (px)
EAT_R = 24
TOUCH_FRAMES = 120
TOUCH_EXT = 300
CHEMO_GAIN = 12         # ext per unit of concentration change (8x oversampled, 0..255 scale)
FOOD_RESPAWN = 120      # frames after eating until a new food glow appears
OMEGA_MIN_BACK = 16     # a reversal shorter than this (frames) ends without an omega turn
AMP_MAX = 12            # px: max lateral wave amplitude a segment's muscles can produce
AMP_SHIFT = 5           # amplitude = (dorsal + ventral activation) >> 5
BIAS_SHIFT = 6          # lateral bias = (dorsal - ventral) >> 6, clamped
BIAS_MAX = 4
WAVE_K = 11             # phase lag per segment (angle units): ~1 wavelength over the body
HEAD_SEGS = 4           # the head segments add a foraging sweep of their own
HEAD_RATE = 3           # head sweep phase advance per frame
HEAD_AMP_SHIFT = 6
HEAD_AMP_MAX = 8
TURN_SHIFT = 10         # heading_q4 += clamp((dorsal-ventral of head muscles, high-passed) >> 10, +-TURN_MAX)
TURN_MAX = 4            # in 1/16 angle units per frame -> at most ~21 deg/s of muscle steering
FOOD_ON_C = 160         # concentration above which the pharynx is driven (the bright core)
PHARYNX_GAIN = 1        # ext to NSM/MC = concentration * gain
NSM_SLOW_FRAMES = 30    # an NSM spike halves the speed for this many frames
FOOD_AMOUNT = 150       # pharyngeal pumps on the food core needed to finish it
OMEGA_TURN = 40         # heading change (angle units, 256 = 360 deg) when forward resumes after a reversal
SWING_AMP = 46          # head swing amplitude, degrees (Q8 angle units: 256 = 360 deg)
SWING_RATE = 6          # phase advance per px of travel (angle units)
SPEED_MAX = 4           # speed unit = 1/4 px per frame -> max 1 px/frame
SPEED_SHIFT = 5
DRIVE_SHIFT = 4
TURN_GAIN = 3           # heading change per frame = bend * gain >> 10

# 256-entry sine table, Q14 (the kernel uses its own copy with the same values)
SIN = [int(round(math.sin(2 * math.pi * i / 256) * 16384)) for i in range(256)]


def isqrt(n):
    if n <= 0:
        return 0
    return int(math.isqrt(n))


def tdiv(a, b):
    """truncating division (x86 idiv), not Python's floor division."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def sin_q14(a):
    return SIN[a & 255]


def cos_q14(a):
    return SIN[(a + 64) & 255]


class Worm:
    def __init__(self, brain=None, seed=0x1234567):
        self.b = brain or Brain()
        self.rng = seed
        self.reset()

    def rand(self):
        x = self.rng & 0xFFFFFFFF
        x ^= (x << 13) & 0xFFFFFFFF; x ^= x >> 17; x ^= (x << 5) & 0xFFFFFFFF
        self.rng = x
        return x

    def reset(self):
        self.b.reset_state()
        self.x = [(DISH_CX - 140 - i * SEG) << 8 for i in range(NSEG)]   # Q8 positions, head = 0
        self.y = [DISH_CY << 8] * NSEG
        self.heading = 0            # angle units, 0 = +x (facing right), 64 = +y (down)
        self.phase = 0
        self.drive = 0              # smoothed fwd-bwd (Q0, scaled)
        self.bend = 0               # smoothed dorsal-ventral head muscle
        self.touch_head = 0
        self.touch_tail = 0
        self.food_x, self.food_y = DISH_CX + 150, DISH_CY - 110
        self.food_on = 1
        self.food_amount = FOOD_AMOUNT
        self.c_now = 0
        self.phase_head = 0
        self.off = [0] * NSEG
        self.dv_slow = 0
        self.steer = 0
        self.steer_acc = 0
        self.nsm_timer = 0
        self.pump = 0
        self.pumps = 0
        self.c_slow = 0
        self.was_back = 0
        self.back_frames = 0
        self.ate = 0
        self.food_timer = 0
        self.nframe = 0
        self.fwd_acc = self.bwd_acc = 0
        self.last_stim = 0

    # ---- environment -> sensory ext ----
    def concentration(self, hx=None, hy=None):
        if not self.food_on:
            return 0
        if hx is None:
            hx, hy = self.x[0] >> 8, self.y[0] >> 8
        dx = hx - self.food_x
        dy = hy - self.food_y
        d2 = dx * dx + dy * dy
        if d2 >= FOOD_R * FOOD_R:
            return 0
        return (FOOD_R * FOOD_R - d2) * 255 // (FOOD_R * FOOD_R)   # quadratic glow, no sqrt

    def sense(self):
        b = self.b
        e = b.bias_ext()
        st = b.stim
        if self.touch_head > 0:
            self.touch_head -= 1
            for k in (0, 1, 2):
                e[st[k]] = sat16(int(e[st[k]]) + TOUCH_EXT)
        if self.touch_tail > 0:
            self.touch_tail -= 1
            for k in (3, 4):
                e[st[k]] = sat16(int(e[st[k]]) + TOUCH_EXT)
        # chemosensation: ASEL is the ON cell (fires while the attractant
        # concentration at the head rises), ASER and AWC are OFF cells (fire while
        # it falls). Falling -> AIB -> RIM -> AVA = the "pirouette" reversal.
        c = self.concentration()
        self.c_slow = self.c_slow - (self.c_slow >> 3) + c         # c_slow ~ 8*c, lagging
        dc = c * 8 - self.c_slow                                   # >0 rising, <0 falling
        self.c_now = c
        if c > FOOD_ON_C:                                             # sitting on food:
            v = min(TOUCH_EXT, c * PHARYNX_GAIN)                      # drive the pharynx
            for k in (12, 13, 14, 15):                                # NSML NSMR MCL MCR
                e[st[k]] = sat16(int(e[st[k]]) + v)
        if dc > 0:
            v = min(TOUCH_EXT, dc * CHEMO_GAIN)
            e[st[5]] = sat16(int(e[st[5]]) + v)                       # ASEL (ON)
        elif dc < 0:
            v = min(TOUCH_EXT, -dc * CHEMO_GAIN)
            e[st[6]] = sat16(int(e[st[6]]) + v)                       # ASER (OFF)
            e[st[7]] = sat16(int(e[st[7]]) + v)                       # AWCL (OFF)
            e[st[8]] = sat16(int(e[st[8]]) + v)                       # AWCR (OFF)
        b.ext = e

    # ---- brain -> motor ----
    def brain_frame(self):
        b = self.b
        fw = bw = 0
        for _ in range(b.steps_per_frame):
            self.sense()
            b.step()
            fw += b.fwd_drive(); bw += b.bwd_drive()
            st = b.stim
            if b.fired(st[12]) or b.fired(st[13]):                    # NSM: slow down on food
                self.nsm_timer = NSM_SLOW_FRAMES
            if b.fired(st[14]) or b.fired(st[15]):                    # MC: a pharyngeal pump
                self.pump = 4
                self.pumps += 1
                if self.food_on and self.c_now > FOOD_ON_C:            # pumping on the lawn eats it
                    self.food_amount -= 1
                    if self.food_amount <= 0:
                        self.eat()
        self.fwd_acc, self.bwd_acc = fw, bw
        # smoothed drive: +fwd -bwd, in units of spikes; decays
        self.drive = self.drive - (self.drive >> DRIVE_SHIFT) + (fw - bw)
        # per-segment lateral offsets from the body-wall muscles: amplitude from the
        # total activation of that segment's muscles, bias from dorsal - ventral
        mp = b.muscle_pairs()
        self.off = []
        for k in range(NSEG):
            md, mv = mp[k]
            amp = max(0, min(AMP_MAX, (md + mv) >> AMP_SHIFT))
            bias = max(-BIAS_MAX, min(BIAS_MAX, (md - mv) >> BIAS_SHIFT))
            o = ((amp * sin_q14((self.phase - k * WAVE_K) & 255)) >> 14) + bias
            if k < HEAD_SEGS:
                hamp = max(0, min(HEAD_AMP_MAX, (md + mv) >> HEAD_AMP_SHIFT))
                o += (hamp * sin_q14(self.phase_head)) >> 14
            self.off.append(o)
        dv = sum(mp[k][0] - mp[k][1] for k in range(8))
        self.dv_slow = self.dv_slow - (self.dv_slow >> 4) + dv                # ~16 * slow mean
        self.steer = max(-TURN_MAX, min(TURN_MAX, (dv * 16 - self.dv_slow) >> TURN_SHIFT))   # high-passed, Q4

    # ---- body kinematics ----
    def move(self):
        spd = self.drive >> SPEED_SHIFT
        spd = max(-SPEED_MAX, min(SPEED_MAX, spd))
        if self.nsm_timer:
            self.nsm_timer -= 1
            spd = tdiv(spd, 2)                                         # on food: slow down
        if self.pump:
            self.pump -= 1
        self.phase_head = (self.phase_head + HEAD_RATE) & 255
        self.steer_acc += self.steer                                   # head muscles steer (Q4 accumulator)
        self.heading = (self.heading + (self.steer_acc >> 4)) & 255
        self.steer_acc &= 15
        if spd == 0:
            return
        if spd > 0 and self.was_back:
            # omega turn after a long reversal: forward resumes in a new direction
            if self.back_frames >= OMEGA_MIN_BACK:
                self.heading = (self.heading + (OMEGA_TURN if self.phase < 128 else -OMEGA_TURN)) & 255
            self.back_frames = 0
        self.was_back = 1 if spd < 0 else 0
        if spd < 0:
            self.back_frames += 1
        self.phase = (self.phase + ((spd * SWING_RATE) >> 2)) & 255   # signed: a reversal runs the wave forward
        if spd > 0:
            lead, nxt, step = 0, 1, 1
            ang = self.heading
        else:
            lead, nxt, step = NSEG - 1, NSEG - 2, -1
            # tail direction = from point NSEG-2 to NSEG-1
            tx = self.x[NSEG - 1] - self.x[NSEG - 2]; ty = self.y[NSEG - 1] - self.y[NSEG - 2]
            ang = iatan2(ty, tx)
        d = abs(spd)
        self.x[lead] += (d * cos_q14(ang)) >> 8       # quarter px * Q14 -> Q8 px
        self.y[lead] += (d * sin_q14(ang)) >> 8
        # follow the leader: each point stays SEG px from the previous one
        i = nxt
        while 0 <= i < NSEG:
            px, py = self.x[i - step], self.y[i - step]
            dx = self.x[i] - px; dy = self.y[i] - py
            dist = isqrt((dx >> 8) * (dx >> 8) + (dy >> 8) * (dy >> 8))   # px
            if dist > 0:
                self.x[i] = px + tdiv(dx * SEG, dist)
                self.y[i] = py + tdiv(dy * SEG, dist)
            i += step
        if spd > 0:
            # keep the stored heading aligned with the body (head segment direction)
            pass
        else:
            # after backing up, the head direction follows the body
            hx = self.x[0] - self.x[1]; hy = self.y[0] - self.y[1]
            self.heading = iatan2(hy, hx)
        # dish wall = a touch on whichever end hit it
        for idx, which in ((0, "head"), (NSEG - 1, "tail")):
            dx = (self.x[idx] >> 8) - DISH_CX; dy = (self.y[idx] >> 8) - DISH_CY
            if dx * dx + dy * dy > (DISH_R - 8) ** 2:
                if which == "head":
                    self.touch_head = max(self.touch_head, TOUCH_FRAMES)
                else:
                    self.touch_tail = max(self.touch_tail, TOUCH_FRAMES)
                # push the point back inside
                dd = isqrt(dx * dx + dy * dy) or 1
                self.x[idx] = (DISH_CX + tdiv(dx * (DISH_R - 10), dd)) << 8
                self.y[idx] = (DISH_CY + tdiv(dy * (DISH_R - 10), dd)) << 8
        # food
        if self.food_on:
            dx = (self.x[0] >> 8) - self.food_x; dy = (self.y[0] >> 8) - self.food_y
            if dx * dx + dy * dy < EAT_R * EAT_R:
                self.eat()
        elif self.food_timer:
            self.food_timer -= 1
            if self.food_timer == 0:
                self.place_food(ahead=False)

    def eat(self):
        self.ate += 1
        self.food_on = 0
        self.food_timer = FOOD_RESPAWN

    def place_food(self, ahead=True):
        if ahead:
            fx = (self.x[0] >> 8) + ((200 * cos_q14(self.heading)) >> 14)
            fy = (self.y[0] >> 8) + ((200 * sin_q14(self.heading)) >> 14)
        else:
            r = self.rand()
            fx = DISH_CX - 220 + (r % 440); fy = DISH_CY - 220 + ((r >> 16) % 440)
        # keep it well inside the dish
        dx, dy = fx - DISH_CX, fy - DISH_CY
        d = isqrt(dx * dx + dy * dy)
        if d > DISH_R - 80:
            fx = DISH_CX + tdiv(dx * (DISH_R - 80), d); fy = DISH_CY + tdiv(dy * (DISH_R - 80), d)
        self.food_x, self.food_y, self.food_on = fx, fy, 1
        self.food_amount = FOOD_AMOUNT

    def frame(self):
        self.brain_frame()
        self.move()
        self.nframe += 1

    def head(self):
        return self.x[0] >> 8, self.y[0] >> 8

    def drawn(self):
        """screen positions: chain point + local normal * muscle offset (what the kernel draws)."""
        pts = []
        for k in range(NSEG):
            a = max(0, k - 1); b = min(NSEG - 1, k + 1)
            tx = (self.x[a] - self.x[b]) >> 8; ty = (self.y[a] - self.y[b]) >> 8   # tangent (px)
            n = isqrt(tx * tx + ty * ty) or 1
            nx = tdiv(-ty * self.off[k], n); ny = tdiv(tx * self.off[k], n)          # normal * offset
            pts.append(((self.x[k] >> 8) + nx, (self.y[k] >> 8) + ny))
        return pts

    def food_dist(self):
        hx, hy = self.head()
        return isqrt((hx - self.food_x) ** 2 + (hy - self.food_y) ** 2)


def iatan2(y, x):
    """angle in 0..255 units (256 = full turn), integer approximation (kernel uses the same)."""
    if x == 0 and y == 0:
        return 0
    ax, ay = abs(x), abs(y)
    # octant-based: t = ay/ax in Q8, angle ~ 32 * t / (1 + 0.28 t^2)... keep simple: table on ratio
    if ax >= ay:
        r = (ay << 8) // ax          # 0..256
        a = ATAN_TAB[r]              # 0..32
    else:
        r = (ax << 8) // ay
        a = 64 - ATAN_TAB[r]
    if x < 0:
        a = 128 - a
    if y < 0:
        a = -a
    return a & 255


ATAN_TAB = [int(round(math.atan(r / 256) / (2 * math.pi) * 256)) for r in range(257)]


if __name__ == "__main__":
    w = Worm()
    def pos(): return w.head(), w.heading, w.drive
    print("start", pos())
    for t in range(120):
        w.frame()
    p0 = w.head(); print("after 120 frames (free crawl)", pos(), "dist food", w.food_dist(), "ate", w.ate)
    w.touch_head = TOUCH_FRAMES
    xs = []
    for t in range(60):
        w.frame(); xs.append((w.drive, w.fwd_acc, w.bwd_acc))
    print("head touch -> drive samples", xs[::6], "pos", pos())
    for t in range(60): w.frame()
    w.touch_tail = TOUCH_FRAMES
    xs = []
    for t in range(60):
        w.frame(); xs.append((w.drive, w.fwd_acc, w.bwd_acc))
    print("tail touch -> drive samples", xs[::6], "pos", pos())
    # chemotaxis: food placed, see if the distance shrinks over time
    w.reset(); w.place_food(ahead=False)
    d0 = w.food_dist(); hist = []
    for t in range(1800):
        w.frame()
        if t % 150 == 0: hist.append(w.food_dist())
        if not w.food_on:
            print("ATE at frame", t); w.place_food(ahead=False)
    print("food dist history", d0, hist, "ate", w.ate)
