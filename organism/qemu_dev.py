#!/usr/bin/env python3
# qemu_dev.py - the organism's development sandbox: boot the AgentZero kernel in
# QEMU (PXE), reachable over UDP so hw.py / skills can drive it exactly as they drive
# the real old PC, and grab framebuffer screenshots over QMP. A cell uses this to try
# an operation safely before (optionally) it is run on the real machine.
#
#   from qemu_dev import QemuKernel
#   with QemuKernel(udp_port=50021, qmp_port=55571) as k:
#       hw = HW("127.0.0.1")            # set AGENTZERO_PORT=<udp_port> first
#       ... drive the kernel ...
#       k.screenshot("out.png")
#
# Pick a UNIQUE udp_port and qmp_port per concurrent instance (this dev PC is shared).
import json, os, socket, subprocess, tempfile, threading, time, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
BAREMETAL = os.path.dirname(HERE)
QEMU = os.environ.get("QEMU",
    r"C:\Users\wu_ha\AppData\Local\Temp\claude\C--Users-wu-ha-Documents-JEV---"
    r"\c56db4d3-a9ae-44e4-9a65-e03ef4ba8c4b\scratchpad\tools\qemu\qemu-system-i386.exe")


def kill_stale(udp_port):
    """Kill any QEMU still holding this udp forward (so a fresh boot can bind it).
    Only matches our hostfwd on this exact port - never another session's kernel."""
    try:
        import subprocess as sp
        out = sp.check_output(
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process -Filter \"name='qemu-system-i386.exe'\" | "
             "Where-Object { $_.CommandLine -match 'hostfwd=udp::%d-' } | "
             "ForEach-Object { $_.ProcessId }" % udp_port],
            text=True, timeout=15)
        for pid in out.split():
            sp.call(["powershell", "-NoProfile", "-Command", "Stop-Process -Id %s -Force" % pid])
    except Exception:
        pass


class QemuKernel:
    def __init__(self, udp_port=50010, qmp_port=55570, img="pxe.img", boot_wait=12.0):
        self.udp_port, self.qmp_port = udp_port, qmp_port
        self.img = os.path.join(BAREMETAL, img)
        self.boot_wait = boot_wait
        self.p = None
        self.serial = bytearray()

    def __enter__(self):
        self.start(); return self

    def __exit__(self, *a):
        self.stop()

    def start(self):
        kill_stale(self.udp_port)
        tftp = os.path.join(tempfile.gettempdir(), "jev_tftp_%d" % self.udp_port)
        os.makedirs(tftp, exist_ok=True)
        shutil.copy(self.img, os.path.join(tftp, "pxe.img"))
        self.p = subprocess.Popen(
            [QEMU, "-boot", "n",
             "-netdev", "user,id=n0,tftp=%s,bootfile=pxe.img,hostfwd=udp::%d-:50000"
             % (tftp, self.udp_port),
             "-device", "e1000,netdev=n0", "-vga", "std",
             "-qmp", "tcp:127.0.0.1:%d,server,nowait" % self.qmp_port,
             "-display", "none", "-no-reboot"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0)
        threading.Thread(target=self._drain, daemon=True).start()
        time.sleep(self.boot_wait)
        return self

    def _drain(self):
        while True:
            b = self.p.stdout.read(1)
            if not b:
                break
            self.serial.extend(b)

    def screenshot(self, path):
        path = os.path.abspath(path).replace("\\", "/")
        q = socket.create_connection(("127.0.0.1", self.qmp_port), timeout=5)
        q.recv(4096)
        q.sendall(b'{"execute":"qmp_capabilities"}\n'); q.recv(4096)
        q.sendall((json.dumps({"execute": "screendump",
                               "arguments": {"filename": path, "format": "png"}}) + "\n").encode())
        time.sleep(0.8); q.recv(65536); q.close()
        return path

    def stop(self):
        if self.p:
            self.p.terminate()
            try:
                self.p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.p.kill()
            self.p = None
