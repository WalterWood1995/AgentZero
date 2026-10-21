#!/usr/bin/env python3
"""make_bgm.py - synthesize a royalty-free ambient electronic background track.

python make_bgm.py <out.wav> <seconds> [--sections "0:calm,84:bright,113:dense"] [--cheer]
--cheer: 120 bpm, major-key "cheer" style, 16th-note arpeggio, synthesized kick/snare/hi-hat.
Sections (start second: style) vary the chord set and arpeggio density so a long
film does not feel static. Pure numpy; no samples, no copyrighted material.
"""
import sys, wave
import numpy as np

out = sys.argv[1]
dur = float(sys.argv[2])
sections = [(0.0, "calm")]
if "--sections" in sys.argv:
    sections = [(float(s.split(":")[0]), s.split(":")[1]) for s in sys.argv[sys.argv.index("--sections") + 1].split(",")]
sr = 44100
n = int(sr * dur)
t = np.arange(n) / sr
rng = np.random.default_rng(11)
N = lambda k: 220 * 2 ** (k / 12)          # semitones above A3
STYLES = {
    # chords (3 notes, Hz), arpeggio sequence, arp density, pad gain
    "calm":   ([(N(0), N(3), N(7)), (N(-4), N(0), N(3)), (N(-9), N(-5), N(-2)), (N(-2), N(2), N(5))],
               [N(7), N(12), N(15), N(19), N(17), N(15), N(12), N(10)], 0.85, 0.08),
    "bright": ([(N(3), N(7), N(10)), (N(-2), N(2), N(5)), (N(0), N(3), N(7)), (N(-4), N(0), N(3))],
               [N(10), N(15), N(19), N(22), N(19), N(15), N(12), N(15)], 0.95, 0.07),
    "dense":  ([(N(0), N(3), N(7)), (N(-4), N(0), N(3)), (N(-2), N(2), N(5)), (N(-9), N(-5), N(-2))],
               [N(7), N(10), N(14), N(19), N(22), N(19), N(14), N(10)], 1.0, 0.09),
    # cheerful: major key (C - G - Am - F), bouncy 16th arpeggio, drums on
    "cheer":  ([(N(3), N(7), N(10)), (N(-2), N(2), N(5)), (N(0), N(3), N(7)), (N(-4), N(0), N(3))],
               [N(15), N(19), N(22), N(27), N(24), N(22), N(19), N(17), N(15), N(19), N(24), N(22)], 1.0, 0.07),
}
BPM = 120 if "--cheer" in sys.argv else 90
DRUMS = "--cheer" in sys.argv
bar = 4.0
pad = np.zeros(n); arp = np.zeros(n); bass = np.zeros(n)

def style_at(sec):
    s = sections[0][1]
    for st, name in sections:
        if sec >= st:
            s = name
    return s

for i in range(int(dur / bar) + 1):
    chords, _, _, gain = STYLES[style_at(i * bar)]
    ch = chords[i % 4]
    s0 = int(i * bar * sr); e0 = min(n, int((i + 1) * bar * sr) + int(0.8 * sr))
    if s0 >= n:
        break
    tt = t[s0:e0] - t[s0]
    env = np.minimum(1, tt / 1.2) * np.minimum(1, np.maximum(0, (e0 - s0) / sr - tt) / 1.0)
    seg = np.zeros(e0 - s0)
    for f in ch:
        for h, a in ((1, 1.0), (2, 0.35), (3, 0.12)):
            seg += a * np.sin(2 * np.pi * f * h * tt + 0.3 * np.sin(2 * np.pi * 0.1 * tt))
    pad[s0:e0] += seg * env * gain
    f = ch[0] / 2
    e1 = min(n, s0 + int(2.5 * sr)); tt = t[s0:e1] - t[s0]
    bass[s0:e1] += 0.12 * np.exp(-tt * 1.2) * np.sin(2 * np.pi * f * tt)

step = 60 / BPM / (4 if DRUMS else 2)
k = 0; tpos = 0.0
while tpos < dur:
    _, seq, dens, _ = STYLES[style_at(tpos)]
    f = seq[k % len(seq)] * (2 if (k // 16) % 4 == 3 else 1)
    if rng.random() < dens:
        s0 = int(tpos * sr); e0 = min(n, s0 + int(0.9 * sr)); tt = t[s0:e0] - t[s0]
        arp[s0:e0] += 0.07 * np.exp(-tt * 3.0) * (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 2 * f * tt))
    k += 1; tpos += step

drums = np.zeros(n)
if DRUMS:
    beat = 60 / BPM
    tpos = 0.0; b = 0
    while tpos < dur:
        s0 = int(tpos * sr)
        if b % 2 == 0:                                   # kick on 1 and 3
            e0 = min(n, s0 + int(0.25 * sr)); tt = t[s0:e0] - t[s0]
            drums[s0:e0] += 0.35 * np.exp(-tt * 18) * np.sin(2 * np.pi * (55 + 80 * np.exp(-tt * 40)) * tt)
        else:                                            # soft snare/clap on 2 and 4
            e0 = min(n, s0 + int(0.12 * sr))
            drums[s0:e0] += 0.12 * np.exp(-(t[s0:e0] - t[s0]) * 30) * rng.normal(0, 1, e0 - s0)
        for h in (0, 0.5):                               # hi-hat on 8ths
            s1 = int((tpos + h * beat) * sr); e1 = min(n, s1 + int(0.04 * sr))
            if s1 < n:
                drums[s1:e1] += (0.05 if h == 0 else 0.035) * np.exp(-(t[s1:e1] - t[s1]) * 90) * rng.normal(0, 1, e1 - s1)
        tpos += beat; b += 1
mix = pad + arp + bass + drums
outp = mix.copy(); d = int(0.31 * sr)
for g in (0.35, 0.18):
    outp[d:] += g * mix[:-d]; d = int(d * 1.6)
noise = np.convolve(rng.normal(0, 1, n), np.ones(400) / 400, "same") * 0.02
outp += noise
fi, fo = int(2.5 * sr), int(5 * sr)
outp[:fi] *= np.linspace(0, 1, fi); outp[-fo:] *= np.linspace(1, 0, fo)
outp = outp / np.max(np.abs(outp)) * 0.5
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((outp * 32767).astype(np.int16).tobytes())
print("bgm %.0f s -> %s" % (dur, out))
