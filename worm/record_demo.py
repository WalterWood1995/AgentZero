#!/usr/bin/env python3
"""record_demo.py - record the demo video of the WORM kernel running in QEMU.

Drives the beats of worm/SHOOTING.md automatically (free crawl, poke head, poke
tail, drop food, eat), grabs a clean screenshot every ~0.1 s (QMP stop /
screendump / cont) and tags each with the kernel's own frame counter, then
assembles an MP4 whose timeline follows the kernel frames (so the worm moves at
the real 60 fps speed, not slowed down by the capture pauses).

Usage: QEMU=<qemu-system-i386> python worm/record_demo.py [out.mp4] [--fps 20]
Needs ffmpeg (preferred) or OpenCV for the encode.
"""
import os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv, args = [sys.argv[0]], sys.argv[1:]
import worm_qemu_test as T

OUT = args[0] if args and not args[0].startswith("--") else os.path.join(os.path.dirname(HERE), "promo", "worm_demo.mp4")
FPS = int(args[args.index("--fps") + 1]) if "--fps" in args else 20
WORK = os.path.join(tempfile.gettempdir(), "jev_worm_rec")
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)

# (seconds of kernel time after the previous beat, key or None, label)
BEATS = [(7.0, None, "free crawl"), (0.0, "h", "poke head"), (6.0, "r", "reset"),
         (1.5, "t", "poke tail"), (5.0, "r", "reset"), (1.5, "f", "drop food"),
         (14.0, None, "eating"), (0.0, "h", "poke head again"), (5.0, None, "end")]


def main():
    vm = T.WormVM()
    time.sleep(2.0)

    def state():
        for _ in range(30):                 # a reset / food redraw stalls the frame loop briefly
            st = vm.state()
            if st:
                return st
            time.sleep(0.1)
        raise SystemExit("kernel stopped answering")
    caps = []                       # (monotonic kernel frame, png path)
    n = 0
    clock = {"off": 0, "last": 0}   # the kernel frame counter restarts at 0 on R: make it monotonic

    def mono(frame):
        if frame + 5 < clock["last"]:
            clock["off"] += clock["last"]
        clock["last"] = frame
        return clock["off"] + frame

    def grab():
        nonlocal n
        vm.qmp({"execute": "stop"})
        path = os.path.join(WORK, "c%05d.png" % n)
        vm.qmp({"execute": "screendump", "arguments": {"filename": path, "format": "png"}})
        vm.qmp({"execute": "cont"})
        st = state()
        caps.append((mono(st["frame"]), path)); n += 1

    if vm.p.poll() is not None:
        raise SystemExit("QEMU exited at once (stale instance holding the QMP port?)")
    # splash (kernel frame counter is 0 until the dish starts): capture it for ~2 s
    for _ in range(12):
        grab(); time.sleep(0.15)
    # wait for the dish
    while True:
        st = state()
        if st["frame"] > 5:
            break
        time.sleep(0.2)
    vm.tap("r")
    t_kernel = mono(state()["frame"])
    try:
        run_beats(vm, state, grab, caps, t_kernel, mono)
    finally:
        time.sleep(0.5)
        vm.close()
    assemble([c for c in caps if os.path.isfile(c[1])])


def run_beats(vm, state, grab, caps, t_kernel, mono):
    for secs, key, label in BEATS:
        target = t_kernel + int(secs * 60)
        while True:
            grab()
            if caps[-1][0] >= target:
                break
            time.sleep(0.05)
        if key:
            vm.tap(key)
            time.sleep(0.3)
        t_kernel = mono(state()["frame"])
        print("beat: %-16s kernel frame %d, %d captures" % (label, t_kernel, len(caps)), flush=True)


def assemble(caps):
    # ---- assemble: output tick k (at FPS) = kernel frame k*60/FPS -> nearest capture ----
    caps.sort()
    seq = []
    f0 = caps[12][0] if len(caps) > 12 else caps[0][0]
    splash = [p for f, p in caps[:12]]
    for p in splash:
        seq += [p] * max(1, int(FPS * 0.15))
    last = caps[-1][0]
    j = 0
    k = 0
    while True:
        want = f0 + int(k * 60 / FPS)
        if want > last:
            break
        while j + 1 < len(caps) and caps[j + 1][0] <= want:
            j += 1
        seq.append(caps[j][1]); k += 1
    lst = os.path.join(WORK, "list.txt")
    with open(lst, "w") as f:
        for p in seq:
            f.write("file '%s'\nduration %.4f\n" % (p.replace("\\", "/"), 1.0 / FPS))
        f.write("file '%s'\n" % seq[-1].replace("\\", "/"))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    ff = shutil.which("ffmpeg")
    if ff:
        subprocess.check_call([ff, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", lst,
                               "-vf", "format=yuv420p", "-r", str(FPS), "-c:v", "libx264", "-crf", "20", OUT])
    else:
        import cv2
        h, w = cv2.imread(seq[0]).shape[:2]
        vw = cv2.VideoWriter(OUT, cv2.VideoWriter_fourcc(*"mp4v"), FPS, (w, h))
        for p in seq:
            vw.write(cv2.imread(p))
        vw.release()
    print(("video: %s  (%d captures -> %d frames at %d fps = %.1f s)" % (OUT, len(caps), len(seq), FPS, len(seq) / FPS)).encode("ascii", "replace").decode())


if __name__ == "__main__":
    main()
