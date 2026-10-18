#!/usr/bin/env python3
# face_anim.py - the "talking face": flap the ASCII portrait's mouth while the
# dev PC speaks an answer. Driven entirely from the dev PC with the kernel's S
# (positioned write) command, so no kernel change / reboot is needed.
#
# "Closed" = the original face glyphs (seamless); "open" = the same rows with a
# dark gap punched in the mouth centre. agent_chat flaps closed<->open ~5 Hz
# while TTS is speaking, then restores the closed mouth.
#
#   python face_anim.py demo           # flap the mouth a few times (check alignment)
#   python face_anim.py open|close     # draw one static frame
import os
import re
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OLD_PC = "192.168.178.114"
R_PORT = 50000

# Mouth region, tweak if the gap doesn't land on the lips (screen = face-relative
# + FACE_COL). Rows are 0-indexed screen rows; cols are indices into the 36-wide
# face row. Overridable via env for quick real-hardware tuning.
MOUTH_ROWS = tuple(int(x) for x in os.environ.get("MOUTH_ROWS", "25,26").split(","))
M0 = int(os.environ.get("MOUTH_C0", "11"))
M1 = int(os.environ.get("MOUTH_C1", "18"))


def _load_face():
    col, w, rows = 42, 36, []
    with open(os.path.join(HERE, "face_data.inc"), "r", encoding="ascii") as f:
        for line in f:
            m = re.match(r"\s*FACE_COL\s+equ\s+(\d+)", line)
            if m:
                col = int(m.group(1))
            m = re.match(r"\s*FACE_W\s+equ\s+(\d+)", line)
            if m:
                w = int(m.group(1))
            m = re.match(r'\s*db\s+"(.*)"\s*$', line)
            if m:
                rows.append(m.group(1))
    return col, w, rows


FACE_COL, FACE_W, FACE_ROWS = _load_face()


def _s_cmd(row, col, text):
    return ("S%02X%02X%s" % (row, col, text)).encode("latin1")


def _send(sock, host, payload):
    for _ in range(3):                           # fire-and-forget redundancy
        sock.sendto(payload, (host, R_PORT))


def _frame_rows(open_):
    """Yield (screen_row, screen_col, text) segments for the mouth region."""
    for r in MOUTH_ROWS:
        if r >= len(FACE_ROWS):
            continue
        seg = list(FACE_ROWS[r][M0:M1])
        if open_:
            # punch a dark gap in the centre to read as an open mouth
            for i in range(len(seg)):
                if 1 <= i <= len(seg) - 2:
                    seg[i] = " "
        yield r, FACE_COL + M0, "".join(seg)


def draw(sock, host, open_):
    for r, c, text in _frame_rows(open_):
        _send(sock, host, _s_cmd(r, c, text))


def flap(sock, host, stop_evt, period=0.18):
    """Flap the mouth until stop_evt is set, then close it."""
    openp = False
    try:
        while not stop_evt.is_set():
            openp = not openp
            draw(sock, host, openp)
            time.sleep(period)
    finally:
        draw(sock, host, False)                  # leave the mouth closed


def _sock():
    return socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "demo"
    host = sys.argv[2] if len(sys.argv) > 2 else OLD_PC
    s = _sock()
    print("mouth rows=%s cols=%d..%d col0=%d" % (MOUTH_ROWS, M0, M1, FACE_COL))
    if mode == "open":
        draw(s, host, True)
    elif mode == "close":
        draw(s, host, False)
    else:
        for _ in range(12):                      # ~2s flap demo
            draw(s, host, True); time.sleep(0.18)
            draw(s, host, False); time.sleep(0.18)
    print("done ->", host)


if __name__ == "__main__":
    main()
