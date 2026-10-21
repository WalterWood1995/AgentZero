#!/usr/bin/env python3
# ascii_art.py - render a photo as a grayscale ASCII portrait for AgentZero's
# green-on-black 80x50 screen. Bright pixels -> dense chars, dark -> space.
#
# Usage: python3 ascii_art.py <image> [width] [--invert]   -> prints the art
from PIL import Image, ImageOps, ImageEnhance
import sys

RAMP = " .:-=+*#%@"                            # 10 levels: space(dark) -> @(bright)


def render(src, W=40, invert=False, rows=50, aspect=1.0):
    # aspect = char cell height/width. VGA 80x50 cells are ~square (~1.0); a tall
    # terminal font would be ~0.5. W is kept small so a portrait is not squashed.
    # src = path or a PIL Image (ascii_cam feeds live camera frames)
    img = (src if isinstance(src, Image.Image) else Image.open(src)).convert("L")
    img = ImageOps.autocontrast(img, cutoff=3)
    img = ImageEnhance.Contrast(img).enhance(1.6)
    if invert:
        img = ImageOps.invert(img)
    H = min(rows, int(W * img.height / img.width * aspect))
    img = img.resize((W, H), Image.LANCZOS)
    px = img.load()
    n = len(RAMP) - 1
    return ["".join(RAMP[int(px[x, y] / 255 * n)] for x in range(W)) for y in range(H)]


if __name__ == "__main__":
    src = sys.argv[1]
    W = next((int(a) for a in sys.argv[2:] if a.isdigit()), 80)
    for ln in render(src, W, "--invert" in sys.argv):
        print(ln)
