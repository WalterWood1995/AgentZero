#!/usr/bin/env bash
# Build + run the AgentZero bare-metal image in QEMU, capturing the COM1
# serial channel (the Agent's headless control line) to stdout.
#
# Usage: ./run.sh [seconds]     # default 8s then QEMU is killed
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
NASM="${NASM:-$(command -v nasm 2>/dev/null || true)}"
QEMU="${QEMU:-qemu-system-i386}"
SECS="${1:-8}"

echo "[build] nasm -f bin boot.asm -> boot.img"
"$NASM" -f bin "$HERE/boot.asm" -o "$HERE/boot.img"
printf '[build] size=%s bytes, sig=' "$(stat -c %s "$HERE/boot.img")"
python -c "d=open(r'$HERE/boot.img','rb').read(); print('%02X%02X'%(d[510],d[511]))"

echo "[run] qemu-system-i386 (serial->stdout, ${SECS}s)"
echo "---- serial ----"
timeout "$SECS" "$QEMU" -drive format=raw,file="$HERE/boot.img" -serial stdio -display none -no-reboot </dev/null 2>/dev/null || true
echo "---- end ----"
