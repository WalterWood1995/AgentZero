#!/usr/bin/env python3
# ascii_cam_qemu_test.py - boot the face/chat kernel (pxe_cam.img) in QEMU on a private
# UDP port, stream the webcam (or a file) through ascii_cam.py for a while with the
# latency probe on, screenshot the result, and print the measured numbers.
#
#   python ascii_cam_qemu_test.py [--img pxe_cam.img] [--secs 20] [--source dario.jpg] [extra ascii_cam args]
#
# Uses its own ports (UDP 50020 / QMP 55620) so it never touches the shared :50000 QEMU.
import argparse, os, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "organism"))
import qemu_dev

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", default="pxe_cam.img")
    ap.add_argument("--secs", type=float, default=20)
    ap.add_argument("--source", default=None)
    ap.add_argument("--udp", type=int, default=50020)
    ap.add_argument("--qmp", type=int, default=55620)
    ap.add_argument("--shot", default=os.path.join(tempfile.gettempdir(), "ascii_cam_qemu.png"))
    a, extra = ap.parse_known_args()
    with qemu_dev.QemuKernel(udp_port=a.udp, qmp_port=a.qmp, img=a.img, boot_wait=12) as vm:
        cmd = [sys.executable, os.path.join(HERE, "ascii_cam.py"), "127.0.0.1", "--port", str(a.udp),
               "--probe", "--duration", str(a.secs)] + (["--source", a.source] if a.source else []) + extra
        env = dict(os.environ, PYTHONUTF8="1")
        p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        t_shot = time.time() + a.secs * 0.6
        shot_done = False
        while True:
            line = p.stdout.readline()
            if not line:
                break
            if not line.startswith(("W0000", "I0000", "WARNING", "INFO")):
                print(line.rstrip(), flush=True)
            if not shot_done and time.time() >= t_shot:
                vm.screenshot(a.shot); shot_done = True
        p.wait()
        if not shot_done:
            vm.screenshot(a.shot)
        print("screenshot:", a.shot)


if __name__ == "__main__":
    main()
