#!/usr/bin/env python3
"""worm_qemu_test.py - unattended QEMU test of the WORM (petri dish) kernel.

Boots disk_worm.img (`WORM=1 bash build.sh`), reads the worm state over the
serial debug line ('G'), injects keys through QMP input-send-event and takes PNG
screenshots (QMP screendump, ASCII temp path). Checks the acceptance behaviours:
  * free crawl: forward motion, the head moves, the brain is active
  * poke head (H): reversal (negative drive, the head moves backward)
  * poke tail (T): forward surge
  * drop food (F): the worm reaches the food and eats it
and optionally records a frame sequence (--record N) for the demo video.

Usage: QEMU=<qemu-system-i386> python worm/worm_qemu_test.py [outdir] [--record N]
"""
import json, os, re, socket, subprocess, sys, tempfile, threading, time

QEMU = os.environ.get("QEMU", "qemu-system-i386")
HERE = os.path.dirname(os.path.abspath(__file__))
BM = os.path.dirname(HERE)
IMG = os.environ.get("WORM_IMG", "disk_worm.img")       # relative to baremetal/ (ASCII path for QEMU)
QMP_PORT = int(os.environ.get("WORM_QMP_PORT", "55591"))
args = [a for a in sys.argv[1:] if not a.startswith("--")]
OUT = args[0] if args else os.path.join(tempfile.gettempdir(), "jev_worm")
RECORD = 0
if "--record" in sys.argv:
    RECORD = int(sys.argv[sys.argv.index("--record") + 1])
os.makedirs(OUT, exist_ok=True)

FIELDS = ["frame", "step", "hx", "hy", "heading", "drive", "spd", "fw", "bw", "th", "tt",
          "fx", "fy", "fon", "ate", "c", "gi", "fired", "tx", "ty", "nsm", "pumps", "amount"]


class WormVM:
    def __init__(self):
        self.p = subprocess.Popen(
            [QEMU, "-drive", "format=raw,file=" + IMG, "-vga", "std", "-m", "128",
             "-serial", "stdio", "-display", "none", "-no-reboot",
             "-qmp", "tcp:127.0.0.1:%d,server,nowait" % QMP_PORT],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0, cwd=BM)
        self.buf = b""
        self.lock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()
        s = None
        for _ in range(100):
            try:
                s = socket.create_connection(("127.0.0.1", QMP_PORT), timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        if s is None:
            self.p.kill()
            raise SystemExit("could not connect to QMP")
        self.f = s.makefile("rwb", buffering=0)
        self.f.readline()
        self.qmp({"execute": "qmp_capabilities"})

    def _reader(self):
        while True:
            b = self.p.stdout.read(1)
            if not b:
                break
            with self.lock:
                self.buf += b

    def qmp(self, req):
        self.f.write((json.dumps(req) + "\n").encode())
        return self.f.readline()

    def key(self, qcode, down):
        self.qmp({"execute": "input-send-event", "arguments": {"events": [
            {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}]}})

    def tap(self, qcode, secs=0.1):
        self.key(qcode, True); time.sleep(secs); self.key(qcode, False); time.sleep(0.05)

    def serial(self, ch, wait=0.08):
        with self.lock:
            self.buf = b""
        self.p.stdin.write(ch.encode()); self.p.stdin.flush()
        time.sleep(wait)
        with self.lock:
            out = self.buf.decode("ascii", "replace")
        return out

    def state(self):
        out = self.serial("G")
        m = re.search(r"= ([0-9A-F ]+)", out)
        if not m:
            return None
        vals = [int(x, 16) for x in m.group(1).split()]
        s32 = lambda v: v - (1 << 32) if v & 0x80000000 else v
        return {n: s32(v) for n, v in zip(FIELDS, vals)}

    def shot(self, name, path=None):
        """Clean frame: pause the VM around the screendump (no tearing), then resume."""
        path = path or os.path.join(OUT, name + ".png")
        self.qmp({"execute": "stop"})
        self.qmp({"execute": "screendump", "arguments": {"filename": path, "format": "png"}})
        self.qmp({"execute": "cont"})
        return path

    def close(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.p.kill()


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg, flush=True)
    return bool(cond)


def sample(vm, secs, every=0.1):
    out = []
    t0 = time.time()
    while time.time() - t0 < secs:
        s = vm.state()
        if s:
            out.append(s)
        time.sleep(every)
    return out


def main():
    ok = True
    vm = WormVM()
    time.sleep(2.5)
    vm.shot("0_splash")
    time.sleep(3.0)                                    # splash is ~100 frames
    try:
        s = vm.state()
        ok &= check(s is not None and s["frame"] > 0, "kernel runs the frame loop: %r" % (s and s["frame"]))
        # ---- 1. free crawl (from the reset pose: ~6 s of open agar ahead) ----
        vm.tap("r"); time.sleep(0.5)
        seq = sample(vm, 3.5)
        fwd = sum(1 for x in seq if x["spd"] > 0); rev = sum(1 for x in seq if x["spd"] < 0)
        moved = abs(seq[-1]["hx"] - seq[0]["hx"]) + abs(seq[-1]["hy"] - seq[0]["hy"])
        ok &= check(fwd > rev * 2 and fwd > len(seq) // 2, "free crawl is mostly forward: fwd %d rev %d of %d" % (fwd, rev, len(seq)))
        ok &= check(moved > 60, "the head travelled: %d px in 3.5 s" % moved)
        ok &= check(max(x["fired"] for x in seq) > 5 and max(x["step"] for x in seq) > 200,
                    "the brain is active: max fired/step %d, steps %d" % (max(x["fired"] for x in seq), seq[-1]["step"]))
        vm.shot("1_crawl")
        # ---- 2. poke head -> reversal (from the reset pose, mid-dish) ----
        vm.tap("r"); time.sleep(1.5)
        before = vm.state()
        vm.tap("h")
        seq = sample(vm, 2.0, 0.02)
        rev = [i for i, x in enumerate(seq) if x["spd"] < 0]
        backed = 0
        if rev:
            backed = seq[rev[0]]["hx"] - min(x["hx"] for x in seq[rev[0]:])   # heading right: backing = x decreases
        ok &= check(len(rev) >= 3 and backed > 2, "poke head -> reversal: %d of %d samples reversing, backed %d px (min drive %d)"
                    % (len(rev), len(seq), backed, min(x["drive"] for x in seq)))
        ok &= check(any(x["th"] > 0 for x in seq[:8]), "ALM/AVM touch input was applied (th>0)")
        vm.shot("2_poke_head")
        time.sleep(2.0)
        # ---- 3. poke tail -> forward surge ----
        vm.tap("r"); time.sleep(0.8)
        base = sample(vm, 1.0, 0.1)
        vm.tap("t")
        seq = sample(vm, 1.5, 0.05)
        ok &= check(any(x["tt"] > 0 for x in seq[:6]), "PLM touch input was applied (tt>0)")
        fw_t = sum(x["fw"] for x in seq) / max(1, len(seq)); fw_b = sum(x["fw"] for x in base) / max(1, len(base))
        ok &= check(all(x["spd"] >= 0 for x in seq) and fw_t >= 0.8 * fw_b,
                    "poke tail -> forward, no reversal (mean fw %.1f vs %.1f before, min drive %d)"
                    % (fw_t, fw_b, min(x["drive"] for x in seq)))
        vm.shot("3_poke_tail")
        time.sleep(1.0)
        # ---- 4. food ahead -> approach and eat (from the reset pose: open agar ahead) ----
        vm.tap("r"); time.sleep(1.5)
        s0 = vm.state()
        vm.tap("f")
        time.sleep(0.3)
        s1 = vm.state()
        ok &= check(s1["fon"] == 1 and (s1["fx"], s1["fy"]) != (s0["fx"], s0["fy"]), "F dropped food at (%d,%d)" % (s1["fx"], s1["fy"]))
        d0 = ((s1["hx"] - s1["fx"]) ** 2 + (s1["hy"] - s1["fy"]) ** 2) ** 0.5
        vm.shot("4_food_dropped")
        ate = s1["ate"]; got = False; dmin = d0; t0 = time.time()
        while time.time() - t0 < 25:
            s = vm.state()
            if s is None:
                continue
            if s["fon"]:
                d = ((s["hx"] - s["fx"]) ** 2 + (s["hy"] - s["fy"]) ** 2) ** 0.5
                dmin = min(dmin, d)
            if s["ate"] > ate:
                got = True
                break
            time.sleep(0.2)
        ok &= check(got, "the worm reached the food and ate it (d0 %.0f, min d %.0f, %.1fs, pumps %d)" % (d0, dmin, time.time() - t0, s["pumps"]))
        ok &= check(s["pumps"] > 0, "pharyngeal pumping happened on the food (MC spikes): %d pumps" % s["pumps"])
        vm.shot("5_food_eaten")
        # ---- 5. reset ----
        vm.tap("r"); time.sleep(0.3)
        s = vm.state()
        ok &= check(s["ate"] == 0 and s["frame"] < 60, "R resets (frame %d, eaten %d)" % (s["frame"], s["ate"]))
        # ---- optional: frame sequence for the demo video ----
        if RECORD:
            rec = os.path.join(OUT, "frames"); os.makedirs(rec, exist_ok=True)
            beats = {int(RECORD * 0.25): "h", int(RECORD * 0.5): "t", int(RECORD * 0.65): "f"}
            vm.tap("r"); time.sleep(0.3)
            for i in range(RECORD):
                if i in beats:
                    vm.tap(beats[i])
                vm.shot(None, os.path.join(rec, "f%04d.png" % i))
                time.sleep(0.08)
            print("recorded %d frames in %s" % (RECORD, rec))
    finally:
        vm.close()
    print("ALL PASS" if ok else "SOME FAILED", flush=True)
    print("screenshots in", OUT)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
