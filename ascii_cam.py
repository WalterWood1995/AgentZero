#!/usr/bin/env python3
# ascii_cam.py - live ASCII avatar: this PC's webcam -> green "digital" ASCII portrait
# -> AgentZero's bare-metal screen over UDP, 10-15 frames/s.
#
# Pipeline (all on the dev PC; the kernel only stores text cells and repaints):
#   webcam -> (optional) face tracking + smoothed 4:3 crop -> grayscale -> temporal EMA
#   -> ascii_art.render (autocontrast + short ramp " .:-=+*#%@") -> 3 brightness tiers
#   (dim green / bright green / white) -> block-write packets:
#       b<2hex row>\n<line>\n...   block write, NO repaint   (frame parts)
#       B<2hex row>\n<line>\n...   block write + repaint      (last part of the frame)
#   Inside a line the bytes 0x01/0x02/0x03 switch the cell attribute (dim/bright/white).
#   'b' and the attribute bytes need the kernel built from this commit (pxe_cam.img);
#   --legacy sends plain 'B' packets that any face/chat kernel (pxe_default.img) accepts
#   (one repaint per packet, single green, so some tearing).
#   Fire-and-forget (display commands are never acked), --repeat N for lossy links.
#
#   python ascii_cam.py                       # QEMU (127.0.0.1 via hostfwd), 12 fps
#   python ascii_cam.py 192.168.178.114 --fps 10 --repeat 2       # the Asus
#   python ascii_cam.py --once                # render one frame to stdout (no network)
#   python ascii_cam.py --subtitle            # + mic -> faster-whisper -> caption row
#
# Screen layout (128x96 text console = the whole 1024x768, 8x8 cells; --screen 80x50 for
# the older image): portrait COLSxROWS centred at the top (default 120x90 = 4:3), caption
# on the last row, which is never fully written (a full last row makes the kernel scroll).
import argparse
import os
import socket
import struct
import sys
import tempfile
import threading
import time

import numpy as np
from PIL import Image

import ascii_art

HERE = os.path.dirname(os.path.abspath(__file__))
RAMP = ascii_art.RAMP
TIER_OF = [1] * 4 + [2] * 3 + [3] * 3          # ramp index -> 1 dim / 2 bright / 3 white
SCR_COLS, SCR_ROWS = 128, 96                     # the kernel's text console (--screen 80x50 = old image)
FACE_MODEL = os.path.join(HERE, "organism", "models", "face_landmarker.task")


# ----------------------------------------------------------------- face tracker
class FaceTracker:
    """mediapipe face landmarks -> smoothed 4:3 crop box (x, y, w, h) in frame pixels.
    Detects on a downscaled frame every `every` frames; the box follows with an EMA
    and a dead band so a still face gives a still crop (no jitter)."""

    def __init__(self, aspect=4 / 3, every=2, zoom=2.1, alpha=0.25, deadband=0.04):
        from mediapipe.tasks.python.vision import FaceLandmarker, FaceLandmarkerOptions
        from mediapipe.tasks.python.core.base_options import BaseOptions
        import mediapipe as mp
        self.mp = mp
        with open(FACE_MODEL, "rb") as f:            # bytes: C open() can't take a CJK path
            buf = f.read()
        cwd = os.getcwd()
        try:
            os.chdir(tempfile.gettempdir())          # runfiles check dislikes non-ASCII cwd
            self.det = FaceLandmarker.create_from_options(
                FaceLandmarkerOptions(base_options=BaseOptions(model_asset_buffer=buf), num_faces=1))
        finally:
            os.chdir(cwd)
        self.aspect, self.every, self.zoom = aspect, every, zoom
        self.alpha, self.deadband = alpha, deadband
        self.n = 0
        self.box = None             # smoothed (cx, cy, h)
        self.miss = 0

    def _detect(self, bgr):
        import cv2
        small = cv2.resize(bgr, None, fx=0.5, fy=0.5)
        rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
        res = self.det.detect(self.mp.Image(image_format=self.mp.ImageFormat.SRGB, data=rgb))
        if not res.face_landmarks:
            return None
        pts = np.array([[p.x, p.y] for p in res.face_landmarks[0]])
        h, w = bgr.shape[:2]
        x0, y0 = pts.min(0) * (w, h)
        x1, y1 = pts.max(0) * (w, h)
        return ((x0 + x1) / 2, (y0 + y1) / 2 - (y1 - y0) * 0.08, (y1 - y0) * self.zoom)

    def crop(self, bgr):
        h, w = bgr.shape[:2]
        self.n += 1
        if self.n % self.every == 0:
            m = self._detect(bgr)
            if m is None:
                self.miss += 1
            else:
                self.miss = 0
                if self.box is None:
                    self.box = m
                else:
                    cx, cy, bh = self.box
                    # dead band: ignore sub-threshold wobble, then EMA towards the target
                    if abs(m[0] - cx) > self.deadband * bh or abs(m[1] - cy) > self.deadband * bh \
                            or abs(m[2] - bh) > self.deadband * 2 * bh:
                        a = self.alpha
                        self.box = (cx + a * (m[0] - cx), cy + a * (m[1] - cy), bh + a * (m[2] - bh))
        if self.box is None or self.miss > 40:     # no face: whole frame (centre crop)
            bh = h
            cx, cy = w / 2, h / 2
        else:
            cx, cy, bh = self.box
        bh = min(max(bh, 80), h)
        bw = min(bh * self.aspect, w)
        bh = bw / self.aspect
        x = int(min(max(cx - bw / 2, 0), w - bw))
        y = int(min(max(cy - bh / 2, 0), h - bh))
        return bgr[y:y + int(bh), x:x + int(bw)]


# ----------------------------------------------------------------- renderer
class Renderer:
    def __init__(self, cols, rows, levels=3, ema=0.55, clahe=True):
        import cv2
        self.cols, self.rows, self.levels, self.ema = cols, rows, levels, ema
        self.acc = None
        # local contrast (CLAHE): a face against a bright window keeps its detail
        self.clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(4, 4)) if clahe else None

    def _grid(self, gray):
        """gray HxW -> smoothed float grid (2x the cell grid)."""
        import cv2
        if self.clahe is not None:
            gray = self.clahe.apply(gray)
        small = cv2.resize(gray, (self.cols * 2, self.rows * 2), interpolation=cv2.INTER_AREA).astype(np.float32)
        if self.acc is None or self.acc.shape != small.shape:
            self.acc = small
        else:
            self.acc += self.ema * (small - self.acc)     # temporal EMA: less sparkle, no lag to speak of
        return self.acc

    def gray_cells(self, gray):
        """For the kernel-render mode: uint8 rows x cols brightness (autocontrast done
        here, the char/attribute mapping is done by the old PC's CPU)."""
        import cv2
        g = self._grid(gray)
        lo, hi = np.percentile(g, 1), np.percentile(g, 99)
        g = np.clip((g - lo) * (255.0 / max(hi - lo, 1)), 0, 255)
        g = np.clip((g - 128) * 1.2 + 128, 0, 255)       # mild boost: the net/table add the punch
        return cv2.resize(g.astype(np.uint8), (self.cols, self.rows), interpolation=cv2.INTER_AREA)

    def render(self, gray):
        """gray: uint8 HxW. Returns rows of (char, tier) tuples as two lists: text lines
        and tier lines (tier 1..3)."""
        img = Image.fromarray(self._grid(gray).astype(np.uint8))
        lines = ascii_art.render(img, self.cols, rows=self.rows, aspect=1.0)
        if len(lines) < self.rows:
            lines += [" " * self.cols] * (self.rows - len(lines))
        tiers = [[TIER_OF[RAMP.index(c)] for c in ln] for ln in lines]
        if self.levels == 1:
            tiers = [[2] * self.cols for _ in lines]
        elif self.levels == 2:
            tiers = [[2 if t < 3 else 3 for t in tl] for tl in tiers]
        return lines, tiers


def encode_line(text, tiers, legacy):
    """One screen row -> bytes with attribute control bytes at tier changes."""
    if legacy:
        return text.encode("latin1")
    out = bytearray()
    cur = 0
    for ch, t in zip(text, tiers):
        if t != cur and ch != " ":                  # spaces draw nothing: don't waste a ctrl byte
            out.append(t)
            cur = t
        out.append(ord(ch))
    return bytes(out)


# ----------------------------------------------------------------- sender
class Screen:
    def __init__(self, ip, port, repeat=1, gap=0.0004, rows_per_packet=8, legacy=False, max_packet=1400):
        self.ip, self.port, self.repeat, self.gap = ip, port, repeat, gap
        self.rpp, self.legacy, self.max_packet = rows_per_packet, legacy, max_packet
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.3)
        self.pkts = 0
        self.bytes = 0

    def send(self, payload):
        for _ in range(self.repeat):
            try:
                self.sock.sendto(payload, (self.ip, self.port))
            except OSError:
                pass
            self.pkts += 1
            self.bytes += len(payload)
            if self.gap:                             # spin: Windows sleep() can't do sub-ms
                t = time.perf_counter() + self.gap
                while time.perf_counter() < t:
                    pass

    def clear(self):
        for _ in range(3):
            self.send(b"X\0")
            time.sleep(0.03)

    def frame(self, lines, tiers, col0, row0=0):
        """Send a whole frame: 'b' parts then a final 'B' (one repaint). Rows are packed
        greedily so no packet exceeds max_packet bytes (kernel RX 1472; real HW ~700)."""
        pad = " " * col0
        enc = [encode_line(pad + ln, [0] * col0 + tl, self.legacy) for ln, tl in zip(lines, tiers)]
        packets, cur, cur_row, size = [], [], 0, 0
        for k, e in enumerate(enc):
            if cur and (size + len(e) + 1 > self.max_packet or len(cur) >= self.rpp):
                packets.append((cur_row, cur)); cur, size = [], 0
            if not cur:
                cur_row, size = k, 4
            cur.append(e); size += len(e) + 1
        if cur:
            packets.append((cur_row, cur))
        for i, (r, body) in enumerate(packets):
            last = i == len(packets) - 1
            head = (b"B" if (last or self.legacy) else b"b") + b"%02X\n" % (row0 + r)
            self.send(head + b"\n".join(body))
        return len(packets)

    def gray_frame(self, cells, col0, row0=0, cmd=b"g"):
        """Kernel-render mode: g<row><repaint flag><raw bytes, SCR_COLS per row> (table
        lookup on the old PC) or, with cmd=b"i", the old PC's neural network (--nn)."""
        rows, cols = cells.shape
        if cmd == b"i":                              # the net renders ALL rows: send the whole
            full = np.zeros((SCR_ROWS, SCR_COLS), dtype=np.uint8)   # grid so no row is stale RAM
            full[row0:row0 + rows, col0:col0 + cols] = cells
            rows, row0 = SCR_ROWS, 0
        else:
            full = np.zeros((rows, SCR_COLS), dtype=np.uint8)
            full[:, col0:col0 + cols] = cells
        rpp = max(1, min(self.rpp, (self.max_packet - 4) // SCR_COLS))
        parts = list(range(0, rows, rpp))
        for i, r in enumerate(parts):
            last = i == len(parts) - 1
            head = cmd + b"%02X%d" % (row0 + r, 1 if last else 0)
            self.send(head + full[r:r + rpp].tobytes())
        return len(parts)

    def pblock(self, lines, tiers, col, row0=0, repaint=True):
        """p<row><col><flag> block write at a column (packed by byte budget); the last
        packet carries the repaint flag."""
        enc = [encode_line(ln, tl, self.legacy) for ln, tl in zip(lines, tiers)]
        packets, cur, cur_row, size = [], [], 0, 0
        for k, e in enumerate(enc):
            if cur and (size + len(e) + 1 > self.max_packet or len(cur) >= self.rpp):
                packets.append((cur_row, cur)); cur, size = [], 0
            if not cur:
                cur_row, size = k, 6
            cur.append(e); size += len(e) + 1
        if cur:
            packets.append((cur_row, cur))
        for i, (r, body) in enumerate(packets):
            last = i == len(packets) - 1
            self.send(b"p%02X%02X%d\n" % (row0 + r, col, 1 if (last and repaint) else 0) + b"\n".join(body))
        return len(packets)

    def load_nn(self):
        """Put nnascii/weights.bin into the old PC's RAM (L, verified) for the 'i' command."""
        sys.path.insert(0, os.path.join(HERE, "organism")); sys.path.insert(0, os.path.join(HERE, "nnascii"))
        from hw import HW
        import nnascii
        blob = open(nnascii.WEIGHTS, "rb").read()
        hw = HW(self.ip, port=self.port, timeout=1.5)
        for _ in range(3):
            if hw.load(nnascii.NN_W_ADDR, blob, chunk=512, verify=True):
                print("neural net weights (%d B) loaded into the old PC at 0x%X" % (len(blob), nnascii.NN_W_ADDR), flush=True)
                return True
        return False

    def dario(self):
        """Draw the kernel's own Dario face (face_data.inc) on the right - dual layout."""
        import re
        col, rows = 42, []
        with open(os.path.join(HERE, "face_data.inc"), "r", encoding="ascii") as f:
            for line in f:
                m = re.match(r"\s*FACE_COL\s+equ\s+(\d+)", line)
                if m:
                    col = int(m.group(1))
                m = re.match(r'\s*db\s+"(.*)"\s*$', line)
                if m:
                    rows.append(m.group(1))
        for r, x in enumerate(rows):                 # positioned writes: the left half (your
            self.send(b"S%02X%02X" % (r, col) + x.encode("latin1"))   # portrait + chat) is untouched
            time.sleep(0.008)                        # each S repaints: pace them or a burst of 46 drops rows

    def caption(self, text):
        w = SCR_COLS - 8
        text = text.encode("ascii", "replace").decode()[:w]
        line = text.center(w)                       # cols 4..: clear of the kernel's keyboard
        self.send(("S%02X04" % (SCR_ROWS - 1)).encode() + line.encode("latin1"))   # HUD (col 0-1), never fills the row

    # -- latency probe: toggle a marker cell, read the framebuffer back with Y until it shows
    def geometry(self, tries=6):
        for _ in range(tries):
            try:
                self.sock.sendto(b"Q\0", (self.ip, self.port))
                data, _ = self.sock.recvfrom(64)
                if len(data) >= 16:
                    return struct.unpack("<4I", data[:16])
            except (OSError, socket.timeout):
                time.sleep(0.3)
        return None

    def read_pixel(self, geo, row, col):
        w, h, pitch, bpp = geo
        x0, y0 = max(0, (w - SCR_COLS * 8) // 2), max(0, (h - SCR_ROWS * 8) // 2)
        off = (y0 + row * 8 + 3) * pitch + (x0 + col * 8) * 4   # pixel (0,3) of '@' is lit in the QEMU and Asus ROM fonts
        try:
            self.sock.sendto(b"Y%08X%04X" % (off, 16), (self.ip, self.port))
            data, _ = self.sock.recvfrom(64)
            return data
        except (OSError, socket.timeout):
            return None


# ----------------------------------------------------------------- captions
class Captions(threading.Thread):
    """Mic -> faster-whisper (local) -> ASCII caption text. The console font is CP437,
    so Chinese can't be shown: by default whisper *translates* to English. Leaves the
    latest text in .text; the main loop paints it."""

    def __init__(self, model="base", seconds=3.0, translate=True, device=None):
        if isinstance(device, str) and device.isdigit():
            device = int(device)
        super().__init__(daemon=True)
        self.model_name, self.seconds, self.translate, self.device = model, seconds, translate, device
        self.text = ""
        self.ok = False

    def run(self):
        try:
            import sounddevice as sd
            from faster_whisper import WhisperModel
            model = WhisperModel(self.model_name, device="cpu", compute_type="int8")
        except Exception as e:
            self.text = "[captions unavailable: %s]" % e.__class__.__name__
            print("captions: %r" % e, flush=True)
            return
        self.ok = True
        sr = 16000
        while True:
            try:
                audio = sd.rec(int(self.seconds * sr), samplerate=sr, channels=1, dtype="float32",
                               device=self.device)
                sd.wait()
                a = audio[:, 0]
                if np.abs(a).max() < 0.01:          # silence: keep the last caption
                    continue
                segs, _ = model.transcribe(a, task="translate" if self.translate else "transcribe",
                                           beam_size=1, vad_filter=True)
                t = " ".join(s.text.strip() for s in segs).strip()
                if t:
                    self.text = t
            except Exception as e:
                self.text = "[caption error]"
                print("captions: %r" % e, flush=True)
                time.sleep(1)


# ----------------------------------------------------------------- sources
def open_camera(index, width=640, height=480):
    """index = number, or -1 = auto: the first camera whose frames arrive in < 300 ms
    (a stuck DirectShow device can answer at exactly 1 frame/s - skip it)."""
    import cv2
    # Media Foundation first: on this PC the DirectShow path of the integrated camera is
    # held by Lenovo's virtual-camera service and only yields black 1 fps frames.
    for api, name in ((cv2.CAP_MSMF, "msmf"), (cv2.CAP_DSHOW, "dshow")):
        for idx in ([index] if index >= 0 else [0, 1, 2, 3]):
            cap = cv2.VideoCapture(idx, api)
            if not cap.isOpened():
                continue
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            ok, dt, fr = True, 0.0, None
            for _ in range(4):
                t = time.time(); ok, fr = cap.read(); dt = time.time() - t
            live = ok and fr is not None and dt < 0.3 and float(fr.mean()) > 2.0   # not a black feed
            if live or (index >= 0 and ok and api == cv2.CAP_DSHOW):
                print("camera %d (%s): %.0f ms/frame, %s" % (idx, name, dt * 1000, fr.shape if fr is not None else "?"), flush=True)
                return cap
            print("camera %d (%s): %s, skipping" % (idx, name, "no frame" if not ok else "%.0f ms/frame mean %.1f" % (dt * 1000, float(fr.mean()) if fr is not None else -1)), flush=True)
            cap.release()
    sys.exit("no usable camera (check Windows camera privacy settings / --list)")


def list_cameras(n=5):
    import cv2
    for i in range(n):
        c = cv2.VideoCapture(i, cv2.CAP_DSHOW)
        if c.isOpened():
            ok, fr = c.read()
            print("camera %d: %s" % (i, fr.shape if ok else "opened, no frame"))
        c.release()
    try:
        import sounddevice as sd
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] > 0:
                print("mic %d: %s" % (i, d["name"].encode("ascii", "replace").decode()))
    except Exception as e:
        print("mics: %r" % e)


def main():
    ap = argparse.ArgumentParser(description="live ASCII avatar for AgentZero")
    ap.add_argument("ip", nargs="?", default="127.0.0.1", help="kernel IP (QEMU hostfwd default)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("AGENTZERO_PORT", "50000")))
    ap.add_argument("--fps", type=float, default=12)
    ap.add_argument("--screen", default="128x96", help="kernel console grid: 128x96 (pxe_cam.img) or 80x50 (older images)")
    ap.add_argument("--cols", type=int, default=0, help="portrait width in cells (default: 4:3 filling the height)")
    ap.add_argument("--rows", type=int, default=0, help="portrait height in cells (default: screen rows - 6)")
    ap.add_argument("--cam", type=int, default=-1, help="camera index (see --list); default auto")
    ap.add_argument("--list", action="store_true", help="enumerate cameras and exit")
    ap.add_argument("--source", default=None, help="video/image file instead of the camera")
    ap.add_argument("--mirror", action="store_true", help="flip horizontally (selfie view)")
    ap.add_argument("--no-track", action="store_true", help="no face tracking (whole frame)")
    ap.add_argument("--levels", type=int, default=3, choices=[1, 2, 3], help="brightness tiers")
    ap.add_argument("--legacy", action="store_true", help="plain B packets (old kernel: pxe_default.img)")
    ap.add_argument("--rows-per-packet", type=int, default=16, help="max rows per packet (bytes cap below applies too)")
    ap.add_argument("--max-packet", type=int, default=1400, help="max UDP payload bytes; use 700 on the real Asus")
    ap.add_argument("--repeat", type=int, default=1, help="send every packet N times (lossy link)")
    ap.add_argument("--gap", type=float, default=0.0004, help="seconds between packets")
    ap.add_argument("--subtitle", action="store_true", help="mic -> whisper caption on the bottom row")
    ap.add_argument("--whisper-model", default="base")
    ap.add_argument("--mic", default=None, help="input device index/name for captions (see --list)")
    ap.add_argument("--no-clahe", action="store_true", help="plain global autocontrast only")
    ap.add_argument("--kernel-render", action="store_true",
                    help="send raw grey bytes; the old PC's CPU maps brightness to chars (g command)")
    ap.add_argument("--nn", action="store_true",
                    help="send raw grey bytes; the old PC's CPU runs the trained MLP (nnascii) that picks each glyph")
    ap.add_argument("--layout", default="single", choices=["single", "dual", "brain", "nn"],
                    help="dual: you (36x36, left) + Dario face (right); agent_chat text fits below; "
                         "brain: you (left) + the C. elegans brain computed by the old PC (right)")
    ap.add_argument("--brain-steps", type=int, default=10, help="brain steps per video frame")
    ap.add_argument("--no-translate", action="store_true", help="caption in the spoken language (ASCII only shows)")
    ap.add_argument("--once", action="store_true", help="render one frame to stdout and exit")
    ap.add_argument("--duration", type=float, default=0, help="stop after N seconds (0 = forever)")
    ap.add_argument("--probe", action="store_true", help="measure send->on-screen latency via Y readback")
    a = ap.parse_args()

    if a.list:
        list_cameras()
        return
    import cv2
    global SCR_COLS, SCR_ROWS
    SCR_COLS, SCR_ROWS = (int(x) for x in a.screen.lower().split("x"))
    big = SCR_COLS >= 128
    if a.layout == "dual":                               # left square portrait, Dario at col 42
        a.cols = a.rows = 36 if not big else 60
        col0 = 2 if not big else 64 - 60 - 2
    elif a.layout == "brain":                            # left square portrait, brain panel right
        a.cols = a.rows = 38 if not big else 64
        col0 = 0
    elif a.layout == "nn":                               # 90x90 picture by the old PC's net + model panel
        a.nn = True
        a.cols = a.rows = 90 if big else 48
        col0 = 0
    else:
        a.rows = a.rows or SCR_ROWS - 6
        a.cols = a.cols or a.rows * 4 // 3
        a.cols = min(a.cols, SCR_COLS)
        a.rows = min(a.rows, SCR_ROWS - 2)
        col0 = (SCR_COLS - a.cols) // 2
    rend = Renderer(a.cols, a.rows, levels=a.levels, clahe=not a.no_clahe)
    tracker = None
    if not a.no_track:
        try:
            tracker = FaceTracker(aspect=a.cols / a.rows)
        except Exception as e:
            print("face tracking off (%r)" % e, flush=True)

    if a.source and a.source.lower().endswith((".jpg", ".jpeg", ".png", ".bmp")):
        still = cv2.imdecode(np.fromfile(a.source, dtype=np.uint8), cv2.IMREAD_COLOR)
        grab = lambda: (True, still.copy())
    else:
        cap = open_camera(a.cam) if not a.source else cv2.VideoCapture(a.source)
        grab = cap.read

    sense = {"motion": 0.0, "approach": 0.0, "prev": None, "prev_h": None}

    def one_frame():
        ok, bgr = grab()
        if not ok:
            return None
        if a.mirror:
            bgr = cv2.flip(bgr, 1)
        if tracker:
            bgr = tracker.crop(bgr)
            bh = bgr.shape[0]
            if sense["prev_h"]:                          # leaning in / out = box height change
                sense["approach"] = 0.7 * sense["approach"] + 0.3 * (bh - sense["prev_h"]) / sense["prev_h"]
            sense["prev_h"] = bh
        else:                                            # centre crop to the cell aspect
            h, w = bgr.shape[:2]
            want = a.cols / a.rows
            if w / h > want:
                nw = int(h * want); bgr = bgr[:, (w - nw) // 2:(w - nw) // 2 + nw]
            else:
                nh = int(w / want); bgr = bgr[(h - nh) // 2:(h - nh) // 2 + nh]
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        g32 = cv2.resize(gray, (32, 32)).astype(np.float32)
        if sense["prev"] is not None:                    # motion energy inside the face box
            sense["motion"] = float(np.abs(g32 - sense["prev"]).mean() / 64.0)
        sense["prev"] = g32
        if a.kernel_render or a.nn:
            return rend.gray_cells(gray), None
        return rend.render(gray)

    if a.once:
        for _ in range(3):                               # let the camera auto-expose
            r = one_frame()
        lines, tiers = r
        if tiers is None:                                # kernel-render: show what the CPU would map
            lines = ["".join(RAMP[int(v) * 10 >> 8] for v in row) for row in lines]
        for ln in lines:
            print(ln)
        return

    scr = Screen(a.ip, a.port, repeat=a.repeat, gap=a.gap, rows_per_packet=a.rows_per_packet, legacy=a.legacy,
                 max_packet=a.max_packet)
    scr.clear()
    if a.nn and not scr.load_nn():
        sys.exit("could not load the NN weights into the kernel (needs pxe_cam.img with the i command)")
    if a.layout == "dual":
        scr.dario()
    nnp = None
    if a.layout == "nn":
        import nn_panel
        nnp = nn_panel.NNPanel(scr.sock, a.ip, a.port, width=SCR_COLS - a.cols - 2, height=SCR_ROWS - 1,
                               pic_rows=a.rows, pic_cols=a.cols)
    brain = None
    if a.layout == "brain":
        import brain_panel
        if big:
            brain = brain_panel.BrainPanel(a.ip, a.port, steps_per_frame=a.brain_steps,
                                           panel_w=SCR_COLS - 66, panel_h=SCR_ROWS, raster_w=64, raster_h=SCR_ROWS - a.rows - 4)
        else:
            brain = brain_panel.BrainPanel(a.ip, a.port, steps_per_frame=a.brain_steps,
                                           panel_w=40, panel_h=48, raster_w=38, raster_h=6)
        if not brain.connect():
            sys.exit("the kernel has no brain (needs pxe_cam.img / default build with HAVE_BRAIN)")
    caps = None
    if a.subtitle:
        caps = Captions(model=a.whisper_model, translate=not a.no_translate, device=a.mic)
        caps.start()
    geo = scr.geometry() if a.probe else None
    if a.probe:
        print("probe geometry: %s" % (geo,), flush=True)

    period = 1.0 / a.fps
    t0 = time.time()
    nxt = t0
    nframes, t_render, t_send, pk_frame = 0, 0.0, 0.0, 0
    last_cap = None
    lat = []
    last_stat = t0
    marker = False
    try:
        while True:
            now = time.time()
            if a.duration and now - t0 > a.duration:
                break
            if now < nxt:
                time.sleep(nxt - now)
            nxt = max(nxt + period, time.time() - period)
            ta = time.time()
            r = one_frame()
            if r is None:
                break
            lines, tiers = r
            if a.probe:                                   # marker cell top-left of the portrait
                marker = not marker
                if tiers is None:
                    lines[0, 0] = 255 if marker else 0
                else:
                    lines[0] = ("@" if marker else " ") + lines[0][1:]
                    tiers[0][0] = 3
            tb = time.time()
            if brain is not None:                         # the old PC runs its brain, we paint it
                brain.tick(sense["motion"], sense["approach"])
                pl, pt = brain.render()
                rl, rt = brain.render_raster()
                leftw = SCR_COLS - brain.W
                nrows = min(SCR_ROWS - 1, brain.H)         # never write the last row fully
                full_l, full_t = [], []
                for r in range(nrows):
                    if r < len(lines):
                        left, lt = lines[r], tiers[r]
                    elif r == len(lines):
                        left = " motion %4.2f  approach %+5.2f   SPIKE RASTER (time ->)" % (sense["motion"], sense["approach"])
                        lt = [1] * len(left)
                    elif r - len(lines) - 1 < len(rl):
                        left, lt = rl[r - len(lines) - 1], rt[r - len(lines) - 1]
                    else:
                        left, lt = "", []
                    left = left.ljust(leftw)[:leftw]
                    lt = (lt + [1] * leftw)[:leftw]
                    full_l.append(left + pl[r]); full_t.append(lt + pt[r])
                lines, tiers = full_l, full_t
            if tiers is None:
                if nnp is not None:
                    nnp.set_probe()                       # which cell the kernel will trace
                pk_frame = scr.gray_frame(lines, col0, cmd=b"i" if a.nn else b"g")
                if nnp is not None:                       # read the traced computation, draw it
                    nnp.read_trace()
                    nnp.n = nframes
                    pl, pt = nnp.render(fps=nframes / max(time.time() - t0, 1e-6))
                    pr, pc = nnp.probe
                    scr.send(b"p%02X%02X0\n\x03@" % (pr, pc))     # mark the probe cell white
                    pk_frame += 1 + scr.pblock(pl, pt, a.cols + 2)
            else:
                pk_frame = scr.frame(lines, tiers, col0)
            tc = time.time()
            if a.layout == "dual" and nframes % int(a.fps * 10) == 0 and nframes:
                scr.dario()                               # redraw the face now and then (lost packets)
            if caps and caps.text != last_cap:
                last_cap = caps.text
                scr.caption(last_cap)
            if a.probe and geo and nframes % int(a.fps) == 0:
                # poll the marker pixel until the kernel has painted this frame
                want = b"\xff\xff\xff" if marker else b"\x00\x00\x00"
                tp = time.time()
                while time.time() - tp < 0.5:
                    d = scr.read_pixel(geo, 0, col0)
                    if d and d[:3] == want:
                        lat.append(time.time() - tc)
                        break
            nframes += 1
            t_render += tb - ta
            t_send += tc - tb
            if time.time() - last_stat >= 2.0:
                el = time.time() - last_stat
                msg = "fps %.1f  render %.1f ms  send %.1f ms  %d pkts/frame  %d B/frame" % (
                    nframes / (time.time() - t0), 1000 * t_render / nframes, 1000 * t_send / nframes,
                    pk_frame * a.repeat, scr.bytes // max(1, nframes))
                if lat:
                    msg += "  kernel latency %.0f ms (n=%d)" % (1000 * sum(lat[-5:]) / len(lat[-5:]), len(lat))
                if caps:
                    msg += "  cap: %s" % caps.text[:40]
                if brain is not None:
                    msg += "  brain step %d fired %d lost %d" % (brain.step_count, int(brain.spk.sum()), brain.lost)
                print(msg, flush=True)
                last_stat = time.time()
    except KeyboardInterrupt:
        pass
    el = time.time() - t0
    print("done: %d frames in %.1fs = %.1f fps, %d packets, %.1f KB/s" % (
        nframes, el, nframes / max(el, 1e-6), scr.pkts, scr.bytes / 1024 / max(el, 1e-6)), flush=True)
    if lat:
        print("send->screen latency: median %.0f ms, max %.0f ms (n=%d)" % (
            1000 * sorted(lat)[len(lat) // 2], 1000 * max(lat), len(lat)))


if __name__ == "__main__":
    main()
