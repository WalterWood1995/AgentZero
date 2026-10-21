#!/usr/bin/env python3
# ascii_cam_record.py - record promo footage: boot pxe_cam.img in QEMU under the
# qemu-screen-record skill (clean QMP screendump frames -> MP4 + GIF) while ascii_cam
# streams the webcam into it. One clip per layout. The real Asus screen cannot be
# captured as video (framebuffer readback is ~5 s/frame), so this is the same kernel
# in QEMU, as with the worm film.
#   PYTHONUTF8=1 python ascii_cam_record.py [--secs 40] [--layouts nn,brain,single] [--source file]
import argparse, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "organism"))
import qemu_dev

REC = os.path.expanduser("~/.claude/skills/qemu-screen-record/scripts/qemu_record.py")
UDP, QMP, BOOT = 50020, 55620, 19


def record(layout, secs, source, fps):
    qemu_dev.kill_stale(UDP)
    tftp = os.path.join(tempfile.gettempdir(), "jev_tftp_%d" % UDP)
    os.makedirs(tftp, exist_ok=True)
    shutil.copy(os.path.join(HERE, "pxe_cam.img"), os.path.join(tftp, "pxe.img"))
    out_tmp = os.path.join(tempfile.gettempdir(), "ascii_cam_%s.mp4" % layout)       # ASCII path for QEMU/ffmpeg
    rec = subprocess.Popen([sys.executable, REC, "--qemu", qemu_dev.QEMU,
                            "--qemu-args", "-boot n -netdev user,id=n0,tftp=%s,bootfile=pxe.img,hostfwd=udp::%d-:50000 "
                                           "-device e1000,netdev=n0 -vga std -display none -no-reboot" % (tftp.replace("\\", "/"), UDP),
                            "--qmp-port", str(QMP), "--boot-wait", str(BOOT), "--duration", str(secs + 12),
                            "--fps", "15", "--interval", "0.06", "--out", out_tmp, "--gif"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # wait until the kernel really answers (the first boot after a kill can take longer)
    import socket
    q = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); q.settimeout(1.0)
    for _ in range(40):
        try:
            q.sendto(b"Q\0", ("127.0.0.1", UDP)); q.recvfrom(64); break
        except (socket.timeout, OSError):
            time.sleep(1)
    q.close()
    time.sleep(2)
    cmd = [sys.executable, os.path.join(HERE, "ascii_cam.py"), "127.0.0.1", "--port", str(UDP),
           "--layout", layout, "--mirror", "--fps", str(fps), "--duration", str(secs)]
    if source:
        cmd += ["--source", source]
    cam = subprocess.run(cmd, env=dict(os.environ, PYTHONUTF8="1"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print("  ascii_cam:", [l for l in cam.stdout.splitlines() if l.startswith(("done", "fps"))][-1:], flush=True)
    log = rec.communicate()[0]
    print("  recorder:", [l for l in log.splitlines() if l.startswith("done")], flush=True)
    os.makedirs(os.path.join(HERE, "promo"), exist_ok=True)
    for ext in (".mp4", ".gif"):
        src = os.path.splitext(out_tmp)[0] + ext
        if os.path.isfile(src):
            dst = os.path.join(HERE, "promo", "ascii_cam_%s%s" % (layout, ext))
            shutil.copy(src, dst)
            print("  -> promo/%s (%d KB)" % (os.path.basename(dst), os.path.getsize(dst) // 1024), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=int, default=40)
    ap.add_argument("--layouts", default="nn,brain,single")
    ap.add_argument("--source", default=None)
    ap.add_argument("--fps", type=int, default=10)
    a = ap.parse_args()
    for layout in a.layouts.split(","):
        print("recording layout %s (%d s)..." % (layout, a.secs), flush=True)
        record(layout, a.secs, a.source, a.fps)


if __name__ == "__main__":
    main()
