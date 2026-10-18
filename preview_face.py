#!/usr/bin/env python3
# Preview an ASCII portrait the way the AgentZero 80x50 green screen shows it
# (near-square cells, green on black). Usage: preview_face.py <img> <out.png> [W]
from PIL import Image, ImageDraw, ImageFont
import sys
import ascii_art

src = sys.argv[1]
out = sys.argv[2]
W = next((int(a) for a in sys.argv[3:] if a.isdigit()), 40)

lines = ascii_art.render(src, W, rows=46)           # same pipeline as the kernel feed

try:
    font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 11)
except OSError:
    font = ImageFont.truetype("C:/Windows/Fonts/cour.ttf", 11)
CW, CH = 9, 9                                        # near-square cell, like VGA 80x50
H = len(lines)
canvas = Image.new("RGB", (W * CW + 8, H * CH + 8), (0, 0, 0))
d = ImageDraw.Draw(canvas)
for y, ln in enumerate(lines):
    for x, ch in enumerate(ln):
        if ch != " ":
            d.text((4 + x * CW, 4 + y * CH), ch, fill=(0, 255, 70), font=font)
canvas.save(out)
print("%s  (%dx%d chars)" % (out, W, H))
