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

"$NASM" -f bin "$SRC/stage1.asm" -o "$SRC/stage1.bin"
"$NASM" -f bin "$SRC/stage2.asm" -o "$SRC/stage2.bin"
"$NASM" -f bin "$SRC/pxe_stage1.asm" -o "$SRC/pxe_stage1.bin"
cat "$HERE/stage1.bin" "$HERE/stage2.bin" > "$HERE/disk.img"          # USB / raw disk
cat "$HERE/pxe_stage1.bin" "$HERE/stage2.bin" > "$HERE/pxe.img"       # PXE network boot
echo "disk.img: $(stat -c %s "$HERE/disk.img") bytes ($(( $(stat -c %s "$HERE/disk.img") / 512 )) sectors)"
echo "pxe.img:  $(stat -c %s "$HERE/pxe.img") bytes"
