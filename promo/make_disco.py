#!/usr/bin/env python3
"""make_disco.py - synthesize a royalty-free psychedelic disco / psytrance style track.

python make_disco.py <out.wav> <seconds> [--bpm 126] [--seed 3]

Four-on-the-floor kick, off-beat hats, claps on 2/4, a rolling 16th sawtooth bass
through a resonant low-pass sweep, detuned saw pads in E minor, an acid arpeggio
with its own filter LFO, side-chain pumping on every kick, ping-pong delay. Pure
numpy (+ scipy for the filters when available). Stereo 44.1 kHz 16-bit.
"""
import sys, wave
import numpy as np

out = sys.argv[1]
dur = float(sys.argv[2])
bpm = float(sys.argv[sys.argv.index("--bpm") + 1]) if "--bpm" in sys.argv else 126.0
seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 3
sr = 44100
n = int(sr * dur)
t = np.arange(n) / sr
rng = np.random.default_rng(seed)
beat = 60.0 / bpm
s16 = beat / 4
try:
    from scipy.signal import lfilter
except Exception:
    lfilter = None


def lowpass(x, cutoff, q=0.7):
    """2-pole resonant low-pass; cutoff may be an array (block-wise coefficients)."""
    cut = np.broadcast_to(np.asarray(cutoff, dtype=float), x.shape)
    y = np.zeros_like(x)
    B = 256
    zi = np.zeros(2)
    for s in range(0, n, B):
        e = min(n, s + B)
        fc = min(max(cut[s], 40.0), 18000.0)
        w0 = 2 * np.pi * fc / sr
        alpha = np.sin(w0) / (2 * q)
        cw = np.cos(w0)
        b = np.array([(1 - cw) / 2, 1 - cw, (1 - cw) / 2]) / (1 + alpha)
        a = np.array([1.0, -2 * cw / (1 + alpha), (1 - alpha) / (1 + alpha)])
        if lfilter is not None:
            y[s:e], zi = lfilter(b, a, x[s:e], zi=zi)
        else:                                   # slow fallback: direct form II transposed
            for i in range(s, e):
                v = x[i]
                yi = b[0] * v + zi[0]
                zi[0] = b[1] * v - a[1] * yi + zi[1]
                zi[1] = b[2] * v - a[2] * yi
                y[i] = yi
    return y


def saw(f, tt, detune=0.0):
    ph = (f * (1 + detune) * tt) % 1.0
    return 2 * ph - 1


N = lambda k: 82.41 * 2 ** (k / 12)             # semitones above E2
# E minor psy progression: Em - Em - C - D (bars of 4 beats)
CHORDS = [(N(0), N(3), N(7)), (N(0), N(3), N(7)), (N(-4), N(0), N(3)), (N(-2), N(2), N(5))]
BASS_PAT = [0, 0, 12, 0, 0, 7, 0, 12, 0, 0, 12, 0, 7, 0, 10, 12]     # semitone offsets per 16th
ARP = [12, 15, 19, 24, 22, 19, 15, 12, 10, 12, 15, 19, 24, 27, 24, 19]

kick = np.zeros(n); hat = np.zeros(n); clap = np.zeros(n)
bass = np.zeros(n); lead = np.zeros(n); padL = np.zeros(n); padR = np.zeros(n)
env_sc = np.ones(n)                                # side-chain gain

nb = int(dur / beat) + 1
for b in range(nb):
    s0 = int(b * beat * sr)
    if s0 >= n:
        break
    e0 = min(n, s0 + int(0.35 * sr)); tt = t[s0:e0] - t[s0]
    kick[s0:e0] += 0.9 * np.exp(-tt * 9) * np.sin(2 * np.pi * (48 + 120 * np.exp(-tt * 30)) * tt)
    env_sc[s0:e0] *= 1 - 0.75 * np.exp(-tt * 12)           # pump
    # off-beat closed hat + open hat on the "and" of 2 and 4
    s1 = int((b + 0.5) * beat * sr); e1 = min(n, s1 + int(0.08 * sr))
    if s1 < n:
        hat[s1:e1] += 0.18 * np.exp(-(t[s1:e1] - t[s1]) * (25 if b % 2 == 0 else 60)) * rng.normal(0, 1, e1 - s1)
    for q in (0.25, 0.75):                                  # 16th ticks
        s2 = int((b + q) * beat * sr); e2 = min(n, s2 + int(0.02 * sr))
        if s2 < n:
            hat[s2:e2] += 0.05 * np.exp(-(t[s2:e2] - t[s2]) * 120) * rng.normal(0, 1, e2 - s2)
    if b % 2 == 1:                                          # clap on 2 and 4
        for d in (0.0, 0.011, 0.023):
            s3 = int((b * beat + d) * sr); e3 = min(n, s3 + int(0.15 * sr))
            if s3 < n:
                clap[s3:e3] += 0.14 * np.exp(-(t[s3:e3] - t[s3]) * 22) * rng.normal(0, 1, e3 - s3)
hat = lowpass(hat, 9000, 0.6) * 0 + hat                     # (keep hats bright)

# rolling bass, 16ths, root from the current chord
bar = 4 * beat
nstep = int(dur / s16) + 1
for i in range(nstep):
    s0 = int(i * s16 * sr)
    if s0 >= n:
        break
    chord = CHORDS[int(i * s16 / bar) % 4]
    f = chord[0] / 2 * 2 ** (BASS_PAT[i % 16] / 12)
    e0 = min(n, s0 + int(s16 * 0.9 * sr)); tt = t[s0:e0] - t[s0]
    env = np.minimum(1, tt / 0.004) * np.exp(-tt * 6)
    bass[s0:e0] += 0.55 * env * (saw(f, tt) + 0.5 * saw(f, tt, 0.004))
    # acid lead: 16ths, sparse accents, octave jumps every 2 bars
    if rng.random() < 0.8:
        fl = chord[0] * 2 ** (ARP[i % 16] / 12) * (2 if (i // 32) % 2 else 1)
        e1 = min(n, s0 + int(s16 * 1.4 * sr)); tt = t[s0:e1] - t[s0]
        lead[s0:e1] += 0.35 * np.minimum(1, tt / 0.003) * np.exp(-tt * 10) * saw(fl, tt)

# pads: 3 detuned saws per note, slow attack, L/R detune for width
for bi in range(int(dur / bar) + 1):
    s0 = int(bi * bar * sr)
    if s0 >= n:
        break
    e0 = min(n, int((bi + 1) * bar * sr) + int(1.0 * sr)); tt = t[s0:e0] - t[s0]
    env = np.minimum(1, tt / 1.5) * np.minimum(1, np.maximum(0, (e0 - s0) / sr - tt) / 1.2)
    for f in CHORDS[bi % 4]:
        padL[s0:e0] += env * (saw(f * 2, tt, -0.006) + saw(f * 2, tt, 0.003)) * 0.07
        padR[s0:e0] += env * (saw(f * 2, tt, 0.006) + saw(f * 2, tt, -0.003)) * 0.07

# filters: bass sweep (slow LFO + per-note), acid lead resonant sweep, pads soft
bass_cut = 180 + 700 * (0.5 + 0.5 * np.sin(2 * np.pi * 0.055 * t)) + 400 * (0.5 + 0.5 * np.sin(2 * np.pi * (bpm / 60 / 4) * t))
bass = lowpass(bass, bass_cut, 2.5)
lead_cut = 400 + 2600 * (0.5 + 0.5 * np.sin(2 * np.pi * 0.09 * t + 1.0)) ** 2
lead = lowpass(lead, lead_cut, 6.0)
padL = lowpass(padL, 1400 + 900 * np.sin(2 * np.pi * 0.03 * t), 0.8)
padR = lowpass(padR, 1400 + 900 * np.sin(2 * np.pi * 0.03 * t + 1.3), 0.8)

# ping-pong delay on the lead (dotted 8th), side-chain on bass/pads
d = int(0.75 * beat * sr)
ldL = lead.copy(); ldR = lead.copy()
ldL[d:] += 0.35 * lead[:-d]; ldR[2 * d:] += 0.25 * lead[:-2 * d]
L = kick + hat * 0.9 + clap + (bass * 0.9 + padL + ldL * 0.5) * env_sc + ldL * 0.15
R = kick + hat * 1.0 + clap + (bass * 0.9 + padR + ldR * 0.5) * env_sc + ldR * 0.15
# arrangement: intro (bars 0-1) without kick/clap, outro fade
intro = int(2 * bar * sr)
L[:intro] -= (kick + clap)[:intro] * np.linspace(1, 0, intro) ** 0.3
R[:intro] -= (kick + clap)[:intro] * np.linspace(1, 0, intro) ** 0.3
fi, fo = int(1.0 * sr), int(5 * sr)
for ch in (L, R):
    ch[:fi] *= np.linspace(0, 1, fi); ch[-fo:] *= np.linspace(1, 0, fo)
# soft clip + normalize
st = np.stack([L, R], 1)
st = np.tanh(st * 1.4)
st = st / np.max(np.abs(st)) * 0.6
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((st * 32767).astype(np.int16).tobytes())
print("disco %.0f s at %.0f bpm -> %s" % (dur, bpm, out))
