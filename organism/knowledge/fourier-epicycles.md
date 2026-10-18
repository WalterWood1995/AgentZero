# Fourier epicycles — the old PC's CPU draws Dario

Target organ: the old PC's **CPU as an evaluator**. A portrait is turned into a chain
of rotating vectors ("epicycles"); the old PC evaluates that Fourier series in integer
fixed point on its own CPU, one frame at a time, and the dev PC renders the returned
points. Developed and verified against the QEMU-hosted AgentZero kernel
(127.0.0.1, UDP :50000 — here udp :50022 / qmp :55572).

The method (coeffs + sine table) is provided by the Claude brain in `fourier.py`; the
**running computation each frame is the old PC's**, via the kernel's `E` command. The
dev PC has the only graphics library — it turns the old PC's numbers into pixels and
blits them; the old PC just copies pixel bytes into its VBE framebuffer.

## 1. Portrait → epicycles (done once, on the dev PC)

`fourier.prepare(image, n_epi, screen) -> (coef_blob, sine_blob, meta)`:

1. **Contour** (`extract_path`): photo → grayscale → bilateral filter → Canny edges →
   the longest few edge contours (face outline, hair, eyes, nose, mouth) are stitched
   into **one ordered closed path** by nearest-endpoint ordering, resampled to N points
   along arc length, scaled/centred to the screen. Result: a complex path `z[n] = x+iy`.
2. **DFT** (`dft_epicycles`): `c = FFT(z)/P`. The DC term `c[0]` becomes the centre
   `(cx, cy)`; every other bin `k` is a rotating vector with signed frequency, radius
   `|c[k]|`, phase `atan2`. Keep the **top `n_epi` by radius** — the biggest wheels
   carry the recognizable shape.
3. **Fixed-point encode** (`encode_coeffs`): a COEF blob = header `{N, cx, cy, _}` then
   `N × {amp, wstep(Q8), phase0(table idx)}`, all int32 LE. `wstep = freq·SIN_LEN·256 /
   period` so that `(wstep·t)>>8` indexes the sine table in step with frequency·time.
4. **Integer sine table** (`sine_table`): `SIN_LEN=1024` entries of `sin(2πi/1024)` in
   **Q14 fixed point** (`1<<14`), int32 LE. Cosine is the same table read a quarter
   turn ahead (`idx + SIN_QUARTER`).

For Dario at `n_epi=64`, `screen=1024×768`: **period = 512**, centre ≈ (516, 280),
COEF blob = **784 bytes** (16-byte header + 64×12), sine table = **4096 bytes**.

## 2. Bulk-load into the old PC's RAM (`L` command)

`hw.load(addr, bytes)` chunks the blob into ≤1200-byte packets, each `L<8hex addr>` +
payload, and waits for an `L`-ack per chunk (so a lossy link retries). Two loads:

- `COEF_BASE = 0x00100000` ← coef blob
- `SIN_BASE  = 0x00120000` ← sine table

The `L` writer is gated to the compute scratch window `[0x100000, 0x180000)` — it can
only touch plain RAM set aside for this, never device MMIO or the kernel.

## 3. The old PC evaluates each frame (`E` command)

`hw.fourier(t)` sends `E<4hex t>`; the **old PC's CPU** runs the epicycle chain in
integer fixed point and returns the point list. For each epicycle, in order:

```
idx  = ((wstep * t) >> 8 + phase0) & 1023      ; table index (Q8 step, mask to SIN_LEN)
s    = sintab[idx]                              ; Q14 sine
c    = sintab[(idx + 256) & 1023]               ; Q14 cosine (quarter turn ahead)
xacc += amp * c                                 ; accumulate wheel contributions
yacc += amp * s
px   = (xacc >> 14) + cx                         ; back to pixels, offset by centre
py   = (yacc >> 14) + cy
```

It returns **N+1 points** (x,y int16 LE each): the centre, then each successive wheel
centre, ending at the **pen tip**. All arithmetic is 32-bit integer with the exact
wraps the kernel's registers/memory do — no floating point on the old PC.

## 4. Render + blit (dev PC)

Per frame (`fourier_dario.run` / `render_frame`): the dev PC draws the turning wheels
(a circle at each point, radius = distance to the next), the connecting arms, the
growing **pen trace** (= the portrait outline so far), the pen-tip marker, and the X/Y
waveforms along the bottom. The frame is RLE-encoded and streamed as `Z`/`G` packets to
the old PC's VBE linear framebuffer. A schedule samples `t` over `[0, period)` for the
requested frame count; a dropped `E` reply rides out on the Python reference so the
animation never stalls.

## 5. Verification

- **Bit-for-bit vs the reference.** `eval_ref` in `fourier.py` mirrors the `E` command
  exactly (same int wraps, same table). A unit run compared the old PC's `E` output to
  `eval_ref` over `t ∈ {0,1,50,128,256,400,511}`: **maxdiff = 0** (every point
  identical) — the old PC computes the Fourier series bit-for-bit.
- **End-to-end on the old PC.** Booted in QEMU (udp :50022 / qmp :55572), loaded the
  64-epicycle Dario coeffs + sine table, drove **120 frames** each computed by the old
  PC via `E`. **0 of 120 E replies dropped** (all 120 returned by the old PC). The QMP
  framebuffer screendump shows the Dario epicycle portrait: head/face outline traced in
  green, the nested turning wheels + arms at the pen, and the X/Y waveforms along the
  bottom. Screenshot: `docs/images/fourier-dario.png`.

## 6. Limitations

- **EPI_MAX = 96** in the kernel: the `E` command evaluates at most 96 epicycles, so
  `n_epi ≤ 96` to keep the preview and the old PC's output identical. 64 already gives
  a recognizable face; more wheels sharpen fine edges at the cost of reply size.
- **Line-art recognizability**: the portrait is a single stitched edge contour, so it
  reads as a Fourier line drawing (outline + features), not a shaded photo. Small
  connecting hops between strokes are normal.
- **Animation speed is bounded by UDP**: each frame is one `E` round-trip plus a full
  framebuffer blit over the lossy link; throughput, not the old PC's CPU, sets the
  frame rate. Passes/delay trade blit completeness against speed.
- Over the **real** old Asus (vs QEMU) the link drops more packets; the reference
  fallback covers dropped `E` replies, and extra blit passes fill dropped scanlines.
