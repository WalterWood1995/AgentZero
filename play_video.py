#!/usr/bin/env python3
# play_video.py - play a video on the AgentZero bare-metal framebuffer. The dev PC
# decodes with ffmpeg (the heavy lifting), downscales to a small centred window, and
# streams only the pixels that CHANGED between frames (delta) as G blits over UDP.
#
# Bare-metal display is fed over a ~0.9k-packet/s UDP pipe, so this is a small,
# low-frame-rate "you can see it move" video, not smooth HD. Lower --size / --fps if
# it can't keep up; raise them if the content is low-motion (delta stays small).
#
#   python play_video.py <video> [old-pc-ip] [--size WxH] [--fps N] [--full]
import os, shutil, socket, struct, subprocess, sys, time

try:
    import numpy as np
    import show_image
except ImportError:
    sys.exit("needs numpy")

PORT = 50000
DEF_IP = "192.168.178.114"
FB_W, FB_H, PITCH = 1024, 768, 1024 * 4
MAXPIX = 360                                     # pixels per packet (<=1472 bytes)


def _ffmpeg():
    for c in ("ffmpeg", shutil.which("ffmpeg")):
        if c and shutil.which(c):
            return shutil.which(c)
    cand = os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages")
    for root, _dirs, files in os.walk(cand):
        if "ffmpeg.exe" in files:
            return os.path.join(root, "ffmpeg.exe")
    raise RuntimeError("ffmpeg not found")


def delta_packets(cur, prev, x0, y0):
    """G packets for the ROWS of `cur` (H,W,4 BGRX) that differ from `prev`. Row-level
    delta: a changed row is sent whole (contiguous, few packets); unchanged rows are
    skipped. This beats pixel-level delta, which fragments on high-motion video."""
    H, W = cur.shape[0], cur.shape[1]
    if prev is None:
        changed = np.ones(H, bool)
    else:
        changed = (cur != prev).any(axis=(1, 2))
    pkts = []
    for y in np.nonzero(changed)[0]:
        rowbytes = cur[y].tobytes()
        base = (y0 + int(y)) * PITCH + x0 * 4
        x = 0
        while x < W:
            n = min(MAXPIX, W - x)
            pkts.append(b"G" + ("%08X" % (base + x * 4)).encode() + rowbytes[x * 4:(x + n) * 4])
            x += n
    return pkts


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    video = sys.argv[1]
    ip, size, fps, full, loop = DEF_IP, (360, 240), 6, False, False
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--size":
            i += 1; w, h = args[i].lower().split("x"); size = (int(w), int(h))
        elif a == "--fps":
            i += 1; fps = int(args[i])
        elif a == "--full":
            full = True; size = (FB_W, FB_H)
        elif a == "--loop":
            loop = True
        elif not a.startswith("--"):
            ip = a
        i += 1
    w, h = size
    x0, y0 = (FB_W - w) // 2, (FB_H - h) // 2
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    cmd = [_ffmpeg(), "-hide_banner", "-loglevel", "error"]
    if loop:
        cmd += ["-stream_loop", "-1"]                # repeat the file forever
    cmd += ["-i", video, "-vf", "scale=%d:%d,fps=%d" % (w, h, fps),
            "-f", "rawvideo", "-pix_fmt", "bgra", "-"]
    print("playing %s at %dx%d, target %d fps -> %s" % (video, w, h, fps, ip))
    # clear the screen to black first (wipe the face/console around the video window)
    show_image.stream_rle(sock, ip, np.zeros((FB_H, FB_W, 4), np.uint8), PITCH, passes=2, delay=0.0004)
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=10 ** 7)
    frame_bytes = w * h * 4
    prev = None
    nfr = 0
    npk = 0
    t0 = time.time()
    period = 1.0 / fps
    try:
        while True:
            raw = p.stdout.read(frame_bytes)
            if len(raw) < frame_bytes:
                break
            cur = np.frombuffer(raw, np.uint8).reshape(h, w, 4).copy()
            cur[..., 3] = 0                          # X byte
            tf = time.time()
            key = (nfr % 15 == 0)                    # periodic full frame: refresh rows the
            pkts = delta_packets(cur, None if key else prev, x0, y0)  # lossy link left stale
            for pk in pkts:
                try:
                    sock.sendto(pk, (ip, PORT))
                except OSError:
                    pass
            prev = cur
            nfr += 1
            npk += len(pkts)
            # pace to target fps (only if we are ahead)
            dt = time.time() - tf
            if dt < period:
                time.sleep(period - dt)
    finally:
        p.terminate()
    el = time.time() - t0
    print("played %d frames in %.1fs (%.1f fps actual), %d packets (%.0f pkt/frame)"
          % (nfr, el, nfr / el if el else 0, npk, npk / nfr if nfr else 0))


if __name__ == "__main__":
    main()
