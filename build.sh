#!/usr/bin/env bash
# AgentZero - assemble stage1 + stage2 and build the bootable images.
#   disk.img : USB / raw-disk boot        pxe.img : PXE network boot
#
# Requires NASM. Point to it with the NASM env var, or have `nasm` on PATH:
#   NASM=/path/to/nasm bash build.sh
#
# On Windows the Git-Bash path may contain non-ASCII chars that nasm.exe mangles
# in argv, so we feed nasm the 8.3 DOS short path (cygpath -d) when available.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
NASM="${NASM:-$(command -v nasm 2>/dev/null || true)}"
if [ -z "$NASM" ]; then
    echo "ERROR: nasm not found. Install NASM and put it on PATH, or set NASM=/path/to/nasm" >&2
    exit 1
fi

SRC="$HERE"
if command -v cygpath >/dev/null 2>&1; then          # Windows: use ASCII short path
    SRC="$(cygpath -u "$(cygpath -d "$(cygpath -w "$HERE")")")"
fi

# IMAGE_DEMO=1 builds the graphics (VBE framebuffer photo) kernel instead of the
# default text face/chat kernel. Only stage2 differs.
# ARCADE=1 builds the game-console kernel (arcade.asm: PS/2 key table + 60 fps
# loop + Pong + Fight). It needs a bigger stage2, so the sector budget define is
# passed to all three sources (stage1 / stage2 / pxe_stage1 must agree).
S2DEF=""
DEFS=""
if [ -n "${IMAGE_DEMO:-}" ]; then
    S2DEF="-dIMAGE_DEMO"
    echo "building IMAGE_DEMO (VBE graphics) kernel"
fi
if [ -n "${ARCADE:-}" ]; then
    DEFS="-dARCADE"
    echo "building ARCADE (game console) kernel"
fi
# WORM=1 builds the C. elegans petri-dish kernel (worm.asm + brain.asm + the
# connectome image). It is written to disk_worm.img / pxe_worm.img so the images
# the PXE server is serving (pxe.img) are never overwritten by accident.
# OUT=<name> writes any build to disk_<name>.img / pxe_<name>.img instead.
OUT="${OUT:-}"
if [ -n "${WORM:-}" ]; then
    DEFS="-dWORM"
    OUT="${OUT:-worm}"
    echo "building WORM (C. elegans petri dish) kernel"
fi
DISK="disk${OUT:+_$OUT}.img"
PXE="pxe${OUT:+_$OUT}.img"

"$NASM" -f bin $DEFS "$SRC/stage1.asm" -o "$SRC/stage1.bin"
"$NASM" -f bin $S2DEF $DEFS "$SRC/stage2.asm" -o "$SRC/stage2.bin"
"$NASM" -f bin $DEFS "$SRC/pxe_stage1.asm" -o "$SRC/pxe_stage1.bin"
cat "$HERE/stage1.bin" "$HERE/stage2.bin" > "$HERE/$DISK"          # USB / raw disk
cat "$HERE/pxe_stage1.bin" "$HERE/stage2.bin" > "$HERE/$PXE"       # PXE network boot
echo "$DISK: $(stat -c %s "$HERE/$DISK") bytes ($(( $(stat -c %s "$HERE/$DISK") / 512 )) sectors)"
echo "$PXE:  $(stat -c %s "$HERE/$PXE") bytes"
