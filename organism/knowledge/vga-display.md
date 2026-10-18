# VGA display controller — 00:02.0 (1234:1111)

The screen the organism draws on. Agent owner: `vga-display`.

## Identity

- **Location:** PCI `00:02.0`
- **Vendor:device:** `1234:1111` — this is the QEMU/Bochs **"stdvga"** (`-vga std`)
  virtual display adapter. Vendor 0x1234 is QEMU's own id; device 0x1111 is its
  standard VGA. (Subsystem `1AF4:1100` = Red Hat / QEMU.)
- **Class:** `030000` — class 03 (Display), subclass 00 (VGA-compatible), prog-if 00.
- **What it is:** a VGA-compatible framebuffer device with the **Bochs VBE / DISPI**
  extension. It gives a legacy VGA text/EGA core plus a large linear framebuffer and
  a small set of "DISPI" index/data registers that set resolution and bit depth
  beyond what plain VGA allows (i.e. VBE 2.0+ graphics modes). It has no 3D engine —
  it is a dumb framebuffer: software writes pixel bytes and the host scans them out.

## Config space (read `python hw.py 127.0.0.1 cfg 0 2 0`)

```
00: 11111234   vendor 0x1234, device 0x1111
04: 00000103   command 0x0103, status 0x0000
08: 03000002   class 03/00/00 (VGA), revision 0x02
0C: 00000000   header type 0, no latency timer / cache line
10: FD000008   BAR0  -> framebuffer (see below)
14: 00000000   BAR1  unused
18: FEBF0000   BAR2  -> MMIO register window
1C..28: 0      BAR3/4/5 unused
2C: 11001AF4   subsystem 1AF4:1100 (Red Hat/QEMU)
30: FEBE0000   expansion ROM base 0xFEBE0000 (bit0=0 -> ROM decode disabled)
34: 00000000   no capabilities pointer
3C: 00000000   no interrupt line/pin wired
40..FC: 0      (no extended/vendor capabilities)
```

### Command register (0x04 low word = 0x0103)
- bit0 **I/O Space enable = 1** — legacy VGA I/O ports (0x3C0–0x3DF) decode.
- bit1 **Memory Space enable = 1** — the BARs below are live and decode.
- bit8 **SERR# enable = 1**.
- Bus-master (bit2) is 0 — this device does no DMA; the CPU does all pixel writes.

## The framebuffer BAR — BAR0 = `FD000008`

- Low bits decode the BAR type: `...1000` → bit0=0 (**memory** BAR, not I/O),
  bits[2:1]=`00` (**32-bit** address space), bit3=1 (**prefetchable**).
- Masking the low 4 type bits: **framebuffer physical base = `0xFD000000`.**
- This is the **linear framebuffer (LFB)**: a flat, prefetchable memory window the
  CPU writes pixels into; byte N maps to a pixel on screen.
- **Size:** cannot be read exactly read-only (that needs a write-all-1s/read-back
  size probe, which we do not do). For QEMU stdvga the LFB BAR is conventionally
  **16 MiB** (0x1000000), enough for the modes the organism uses
  (1024×768×32bpp = 3 MiB; 1920×1080×32bpp ≈ 7.9 MiB — both fit).

## The MMIO register BAR — BAR2 = `FEBF0000`

- bit0=0 (memory), bits[2:1]=00 (32-bit), bit3=0 (**non-prefetchable**) →
  **MMIO register window at `0xFEBF0000`.**
- This is the QEMU stdvga MMIO bank: it exposes the **Bochs DISPI** index/data
  registers (set xres/yres/bpp/enable, bank, virtual size, x/y offset) and a
  memory-mapped copy of the legacy VGA ports. It is how a driver *programs* a mode
  without the VBE BIOS; the organism does not use it (see below).

## Expansion ROM — 0x30 = `FEBE0000`

Base `0xFEBE0000` for the VGA BIOS option ROM, but bit0 (ROM decode enable) is 0, so
it is not currently mapped into the memory window. The VGA BIOS is what services the
`int 10h` / VBE calls the organism relies on at boot.

## How the organism currently uses this device

The organism does **not** touch BAR0/BAR2 directly to set up video. At boot, in
16-bit real mode where the VGA BIOS is available, `stage2.asm`:

1. `vbe_probe` calls VBE BIOS `AX=4F00` (controller info) and `AX=4F01`
   (mode info), scanning for a 32-bpp linear-framebuffer mode (prefers 1024×768).
2. It reads the **framebuffer physical base from the VBE ModeInfoBlock at offset
   0x28 (`PhysBasePtr`)** — `stage2.asm:454: mov eax, [vbe_modeinfo+0x28]`. That
   value is exactly the base the BIOS programmed into **BAR0 = `0xFD000000`**: the
   VBE `PhysBasePtr` and PCI BAR0 point at the same LFB. It also saves pitch, bpp,
   width, height, mode number.
3. `vbe_setup` / `gfx_enter` switch to that mode (`AX=4F02` with the LFB bit set).
4. Thereafter the kernel renders purely by **writing pixels to physical memory** at
   `fb_base + y*pitch + x*4` (BGRX/XRGB 32bpp). The text console, face/chat, full
   screen photos (`show_image.py`), web pages (`webread.py`) and video
   (`play_video.py`) are all drawn as raw pixel bytes into this LFB — which is the
   memory region BAR0 decodes.

So: **BAR0 (`0xFD000000`) is the surface; VBE just tells the kernel its address,
geometry and bit depth.** No DMA, no interrupt — the CPU stores pixels and QEMU
scans them out to the display.

## How one draws to it (summary)

- Framebuffer base: `0xFD000000` (BAR0 / VBE PhysBasePtr).
- A pixel at (x,y): `base + y*pitch + x*(bpp/8)`; 32bpp pixel = 0x00RRGGBB (XRGB).
- Enable Memory Space (command bit1, already set) before the BAR decodes.
- Read-only probing (what this Agent does) never touches the LFB; writing pixels is
  a gated memory/framebuffer write and belongs in a reviewed skill, not a probe.

## Open questions

- **Exact LFB size** (needs a BAR size probe = a write; assumed 16 MiB).
- **DISPI MMIO map at `0xFEBF0000`**: exact register offsets (DISPI index/data,
  bank window) — could be read-probed, but the organism doesn't need them while it
  uses the VBE BIOS path.
- Current **active mode geometry** (pitch/width/height/bpp) lives in the kernel's
  `vbe_*` variables, set at boot — not readable from PCI config space.
- Whether enabling the expansion ROM (0x30 bit0) would let an Agent re-invoke the
  VGA BIOS after boot (not needed today).
