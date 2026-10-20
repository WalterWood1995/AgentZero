#!/usr/bin/env python3
"""arcade_qemu_test.py - unattended QEMU test of the ARCADE kernel.

Boots disk_arcade.img (build with `ARCADE=1 bash build.sh`, then copy disk.img),
drives the PS/2 keyboard through QMP input-send-event (key down / key up, so
the kernel's held-key table is exercised, not just taps), reads the kernel's
serial debug line ('H' = held scancodes, 'G' = game state) and grabs PNG
screenshots with QMP screendump (ASCII temp path - QEMU can't write CJK paths).

Usage: python arcade_qemu_test.py [outdir]
"""
import json, os, re, socket, subprocess, sys, tempfile, threading, time

QEMU = os.environ.get("QEMU", "qemu-system-i386")
HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.environ.get("ARCADE_IMG", "disk_arcade.img")   # relative: QEMU on Windows can not open a CJK path
QMP_PORT = int(os.environ.get("QMP_PORT", "55590"))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "jev_arcade")
os.makedirs(OUT, exist_ok=True)


class Arcade:
    def __init__(self):
        self.p = subprocess.Popen(
            [QEMU, "-drive", "format=raw,file=" + IMG, "-vga", "std",
             "-serial", "stdio", "-display", "none", "-no-reboot",
             "-qmp", "tcp:127.0.0.1:%d,server,nowait" % QMP_PORT],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0, cwd=HERE)
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

    def hold(self, *qcodes):
        for q in qcodes:
            self.key(q, True)

    def release(self, *qcodes):
        for q in qcodes:
            self.key(q, False)

    def tap(self, qcode, secs=0.08):
        self.hold(qcode); time.sleep(secs); self.release(qcode); time.sleep(0.05)

    def serial(self, ch, wait=0.3):
        with self.lock:
            self.buf = b""
        self.p.stdin.write(ch.encode()); self.p.stdin.flush()
        time.sleep(wait)
        with self.lock:
            out = self.buf.decode("ascii", "replace")
        return out.strip()

    def held(self):
        out = self.serial("H")
        m = re.search(r"keys:\s*([0-9A-F ]*)", out)
        return m.group(1).split() if m else None

    def game(self):
        out = self.serial("G")
        m = re.search(r"= ([0-9A-F ]+?)\s+f\(.*?\): ([0-9A-F ]+)\|([0-9A-F ]+)", out, re.S)
        if not m:
            return None
        u32 = lambda s: [int(x, 16) for x in s.split()]
        s32 = lambda v: v - (1 << 32) if v & 0x80000000 else v
        g = u32(m.group(1))
        names = ["mode", "p1y", "p2y", "ballx", "bally", "vx", "vy", "s1", "s2", "serve", "win", "frame"]
        d = {n: s32(v) for n, v in zip(names, g)}
        fn = ["x", "y", "vy", "face", "hp", "atk", "cd", "stun", "hit"]
        d["f1"] = {n: s32(v) for n, v in zip(fn, u32(m.group(2)))}
        d["f2"] = {n: s32(v) for n, v in zip(fn, u32(m.group(3)))}
        return d

    def shot(self, name):
        path = os.path.join(OUT, name + ".png")
        self.qmp({"execute": "screendump", "arguments": {"filename": path, "format": "png"}})
        time.sleep(0.3)
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


def main():
    ok = True
    a = Arcade()
    time.sleep(3.0)                                   # boot straight into the menu
    try:
        # ---- 1. keyboard held-key table ----
        ok &= check(a.held() == [], "no keys held at boot: %r" % a.held())
        a.hold("w", "up")
        time.sleep(0.2)
        h = a.held()
        ok &= check(h == ["11", "C8"], "W + Up held -> 11 C8: %r" % h)
        a.release("w")
        time.sleep(0.2)
        h = a.held()
        ok &= check(h == ["C8"], "W released -> only C8: %r" % h)
        a.release("up")
        time.sleep(0.2)
        ok &= check(a.held() == [], "all released: %r" % a.held())
        a.shot("1_menu")

        # ---- 2. Pong ----
        a.tap("1")
        time.sleep(0.3)
        g = a.game()
        ok &= check(g and g["mode"] == 1, "entered pong: %r" % (g and g["mode"]))
        p1y0, p2y0 = g["p1y"], g["p2y"]
        a.hold("w", "down")
        time.sleep(0.5)
        a.release("w", "down")
        g = a.game()
        ok &= check(g["p1y"] < p1y0, "P1 paddle moved up: %d -> %d" % (p1y0, g["p1y"]))
        ok &= check(g["p2y"] > p2y0, "P2 paddle moved down: %d -> %d" % (p2y0, g["p2y"]))
        time.sleep(1.5)                                # ball launches after the serve delay
        g1 = a.game(); time.sleep(0.3); g2 = a.game()
        ok &= check(g1["ballx"] != g2["ballx"], "ball moving: x %d -> %d" % (g1["ballx"], g2["ballx"]))
        a.shot("2_pong")
        # let it play ~25 s (paddles parked -> points get scored)
        for _ in range(25):
            time.sleep(1.0)
            g = a.game()
            if g["mode"] == 3:
                break
        ok &= check(g["s1"] + g["s2"] > 0, "points scored: %d : %d (mode %d)" % (g["s1"], g["s2"], g["mode"]))
        a.shot("3_pong_late")
        a.tap("esc")
        time.sleep(0.3)
        ok &= check(a.game()["mode"] == 0, "Esc -> menu")

        # ---- 3. Fight ----
        a.tap("2")
        time.sleep(0.3)
        g = a.game()
        ok &= check(g["mode"] == 2, "entered fight")
        ok &= check(g["f1"]["hp"] == 100 and g["f2"]["hp"] == 100, "both at 100 hp")
        a.shot("4_fight_start")
        a.hold("w")                                    # P1 jumps
        time.sleep(0.2)
        g = a.game()
        ok &= check(g["f1"]["y"] > 0, "P1 jumping: y=%d" % g["f1"]["y"])
        a.release("w")
        a.hold("d")                                    # P1 walks right to P2
        time.sleep(2.0)
        a.release("d")
        g = a.game()
        ok &= check(g["f2"]["x"] - g["f1"]["x"] <= 60, "P1 reached P2: x %d vs %d" % (g["f1"]["x"], g["f2"]["x"]))
        a.hold("f")                                    # mash punch (cooldown paces it)
        time.sleep(1.5)
        g = a.game()
        a.shot("5_fight_punch")
        ok &= check(g["f2"]["hp"] < 100, "P2 took damage: hp=%d" % g["f2"]["hp"])
        a.hold("d")                                    # keep chasing (knockback pushes P2 away)
        for _ in range(30):
            time.sleep(0.5)
            g = a.game()
            if g["mode"] == 4:
                break
        a.release("f", "d")
        ok &= check(g["mode"] == 4 and g["win"] == 1, "KO -> P1 wins (mode %d win %d, hp2=%d)" % (g["mode"], g["win"], g["f2"]["hp"]))
        a.shot("6_fight_ko")
        a.tap("spc")
        time.sleep(0.3)
        g = a.game()
        ok &= check(g["mode"] == 2 and g["f2"]["hp"] == 100, "Space -> rematch")
        a.tap("esc"); time.sleep(0.2)
        ok &= check(a.game()["mode"] == 0, "Esc -> menu again")
    finally:
        a.close()
    print("ALL PASS" if ok else "SOME FAILED", flush=True)
    print("screenshots in", OUT)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
