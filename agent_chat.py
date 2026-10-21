#!/usr/bin/env python3
# agent_chat.py - dev-PC side of the AgentZero chat terminal.
# The old PC sends the typed question here over UDP (port 50001); we answer and
# send the text back to the old PC's screen (port 50000) as kernel display
# commands (left column, the face stays on the right).
#
# answer() asks Claude (the Anthropic API) when a key is available - from the
# ANTHROPIC_API_KEY env var, or an `api_key.txt` next to this file - and falls
# back to the built-in canned replies if there's no key or the call fails, so
# the proven network loop never breaks.
import os
import queue
import socket
import subprocess
import sys
import textwrap
import threading
import time

try:
    import show_image                              # stream a photo to the VBE framebuffer
    import webshot                                 # screenshot a web page with headless Chrome
    import webread                                 # parse a page into reader pages (text+images+links)
except Exception as _e:                            # keep chat working even if these fail to import
    show_image = webshot = webread = None
    print("image display unavailable (%r)" % _e, flush=True)

Q_PORT = 50001          # we listen here (questions from the old PC)
CHAT_ROW0 = int(os.environ.get("CHAT_ROW0", "0"))   # first screen row of the dialogue pane
                        # (ascii_cam --layout dual: CHAT_ROW0=38 CHAT_PANE_H=10 puts it under your portrait)
R_PORT = 50000          # kernel listens here (display commands)
LEFT_W = 38             # left dialogue column width (face is on the right)
PANE_H = int(os.environ.get("CHAT_PANE_H", "14"))   # left dialogue height: pad every reply to this many rows so a
                        # shorter answer fully clears the previous one (stays < the
                        # kernel's 760-byte UDP read buffer: 14*41 + 4 ~= 578 bytes)

# Claude backend. Model is overridable with ANTHROPIC_MODEL in case the default
# id isn't enabled on your account; on any API error we fall back to canned.
MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5-5")
SYSTEM = (
    "You are AgentZero, an AI agent running a bare-metal x86 machine at ring 0 with no "
    "operating system and no software - just a tiny kernel an agent drives over the network. "
    "You live on a 2009 Asus netbook, likely the first OS-less, agent-driven netbook on Earth. "
    "Answer in character, in plain ASCII only, and VERY concisely (at most ~50 words): your "
    "reply is painted onto a 40-column bare-metal text screen, so long answers are unreadable."
)


INTRO = (
    "I am AgentZero. This old Asus has no OS and no "
    "software - just a tiny bare-metal kernel at ring 0 "
    "that an AI agent drives over the network. You type "
    "here; the keystrokes leave the machine as raw UDP; "
    "the agent answers and paints the text straight into "
    "video memory. Likely the first netbook on Earth run "
    "by an agent and skills alone - no operating system."
)


def _api_key():
    k = os.environ.get("ANTHROPIC_API_KEY")
    if k and k.strip():
        return k.strip()
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "api_key.txt"), "r") as f:
            k = f.read().strip()
            return k or None
    except OSError:
        return None


def _workspace_id():
    w = os.environ.get("ANTHROPIC_WORKSPACE_ID")
    if w and w.strip():
        return w.strip()
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "workspace_id.txt"), "r") as f:
            w = f.read().strip()
            return w or None
    except OSError:
        return None


_client = None
_client_tried = False


def _client_get():
    global _client, _client_tried
    if _client_tried:
        return _client
    _client_tried = True
    try:
        import anthropic
        key = _api_key()
        if not key:
            print("no ANTHROPIC_API_KEY / api_key.txt - using canned replies", flush=True)
            return None
        headers = {}
        wsid = _workspace_id()
        if wsid:                                 # org-scoped keys need the workspace header
            headers["anthropic-workspace-id"] = wsid
        _client = anthropic.Anthropic(api_key=key, default_headers=headers or None,
                                      timeout=15, max_retries=0)
        print("Claude backend ready (model %s%s)"
              % (MODEL, ", workspace " + wsid if wsid else ""), flush=True)
    except Exception as e:
        print("anthropic unavailable (%r) - using canned replies" % e, flush=True)
    return _client


_UNI = {"—": "-", "–": "-", "’": "'", "‘": "'",
        "“": '"', "”": '"', "…": "...", " ": " "}


def _ascii(s):
    for a, b in _UNI.items():
        s = s.replace(a, b)
    return s.encode("ascii", "replace").decode("ascii")


def llm_answer(q):
    c = _client_get()
    if c is None:
        return None
    try:
        msg = c.messages.create(
            model=MODEL, max_tokens=256, system=SYSTEM,
            messages=[{"role": "user", "content": q}],
            timeout=15,                              # never let a slow API stall the loop
        )
        text = "".join(getattr(b, "text", "") for b in msg.content
                        if getattr(b, "type", "") == "text")
        text = _ascii(" ".join(text.split()))
        return text or None
    except Exception as e:
        print("LLM error (falling back to canned): %r" % e, flush=True)
        return None


def _canned(q):
    low = q.lower()
    if low in ("hi", "hello", "hey"):
        return "Hello. I am AgentZero, running on bare metal, ring 0, no OS. Ask me to introduce myself."
    if ("intro" in low or "introduc" in low or "介绍" in q
            or "who" in low or "what is" in low or "about" in low
            or "agentzero" in low or "agent zero" in low):
        return INTRO
    return "You said: " + q


def answer(q):
    q = q.strip()
    if not q:
        return "..."
    low = q.lower()
    if low in ("hi", "hello", "hey"):        # fast path (the kernel auto-sends 'hello'
        return _canned(q)                    # at boot; never call the LLM for it)
    # "web <domain>" / "go <domain>" -> fetch that page and show a screen digest
    if low.startswith("web ") or low.startswith("go "):
        target = q.split(None, 1)[1].strip() if len(q.split(None, 1)) > 1 else ""
        if target:
            try:
                import web
                return web.web_answer(target, _client_get(), _ascii)
            except Exception as e:
                return "web error: %r" % e
    return llm_answer(q) or _canned(q)


# ---- web reader + image display on the old PC's screen ----
# A separate UDP socket for display sends (the kernel's acks come back here, not to
# the question listener). _showing = a full-screen image/page is up; _reader holds
# the current parsed page's rendered pages + numbered links for keyboard navigation.
_disp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
_disp.settimeout(1.5)
_showing = {"on": False}
_reader = {"pages": None, "links": [], "cur": 0, "url": "", "pil": None, "sel": None}
_kseq = {"v": None}                                # last per-key sequence byte (dedup)
_disp_lock = threading.Lock()                      # serialize framebuffer sends
_loading = {"on": False}                           # a page is being fetched/rendered
WEB_VERBS = ("web ", "read ", "seite ", "lies ")   # all lowercase, no Shift -> reader
SHOT_VERBS = ("shot ", "pic ", "bild ")            # full-page screenshot instead
R_MARGIN = 40                                      # must match webread.MARGIN (cursor column)


def _links_on_page(p):
    return [i for i, l in enumerate(_reader["links"]) if l["page"] == p]


def _draw_cursor(peer, idx, marked):
    """Blit the left-margin band at link `idx`, with or without the > marker."""
    if idx is None or _reader["pil"] is None:
        return
    link = _reader["links"][idx]
    y0 = max(0, link["y0"] - 4)
    band = _reader["pil"].crop((0, y0, R_MARGIN, y0 + 30)).convert("RGB")
    if marked:
        from PIL import ImageDraw
        ImageDraw.Draw(band).polygon([(10, 5), (10, 25), (31, 15)], fill=(210, 30, 30))
    show_image.blit_at(peer, band, 0, y0, sock=_disp)


def _move_cursor(peer, delta):
    """Move the link cursor by delta across the whole document, auto-paging to the
    link's page if it is on a different one."""
    links = _reader["links"]
    if not links:
        return
    cur = _reader["sel"]
    new = (0 if delta > 0 else len(links) - 1) if cur is None else cur + delta
    if new < 0 or new >= len(links):
        return
    with _disp_lock:
        if links[new]["page"] != _reader["cur"]:      # cursor moved to another page
            _reader["cur"] = links[new]["page"]
            _reader["pil"] = _reader["pages"][_reader["cur"]]
            show_image.blit_frame(peer, _reader["pil"], rle=True, passes=4, delay=0.0007, sock=_disp)
            _reader["sel"] = new
            _draw_cursor(peer, new, True)
        else:
            _draw_cursor(peer, cur, False)            # same page: just move the marker
            _reader["sel"] = new
            _draw_cursor(peer, new, True)


def _send_text(sock, peer, a, q=None):
    """Paint a Q/A reply onto the old PC's left column (one padded block write)."""
    lines = []
    if q is not None:
        lines.append("Q: " + q)
    for ln in textwrap.wrap("A: " + a, LEFT_W) or ["A:"]:
        lines.append(ln)
    lines = lines[:PANE_H]
    while len(lines) < PANE_H:
        lines.append("")
    payload = "B%02X\n" % CHAT_ROW0 + "\n".join(l.ljust(40)[:40] for l in lines)
    for _ in range(4):
        sock.sendto(payload.encode("latin1"), (peer, R_PORT))


def _blit_page(peer):
    """Blit the current reader page, then place the cursor on its first link."""
    pages = _reader["pages"]
    if not pages:
        return
    p = _reader["cur"]
    _reader["pil"] = pages[p]
    show_image.blit_frame(peer, pages[p], rle=True, passes=4, delay=0.0007, sock=_disp)
    _showing["on"] = True
    onp = _links_on_page(p)
    _reader["sel"] = onp[0] if onp else None
    if _reader["sel"] is not None:
        _draw_cursor(peer, _reader["sel"], True)


def open_url(peer, url):
    """Fetch + render a page in the BACKGROUND (news pages take several seconds), so
    the service stays responsive to navigation while it loads. Shows it when ready."""
    if webread is None:
        return False
    if "://" not in url:
        url = "https://" + url
    if _loading["on"]:
        return True                                  # already loading one; ignore
    _loading["on"] = True

    def _work():
        try:
            pages, links = webread.render(url)
            _reader.update(pages=pages, links=links, cur=0, url=url)
            with _disp_lock:
                _blit_page(peer)
            print("reader: %s  (%d pages, %d links)" % (url, len(pages), len(links)), flush=True)
        except Exception as e:
            print("webread error: %r" % e, flush=True)
        finally:
            _loading["on"] = False

    threading.Thread(target=_work, daemon=True).start()
    return True


def show_shot(peer, target):
    """Full-page screenshot (not reflowed) streamed to the screen."""
    png = webshot.screenshot(target)
    show_image.show(png, peer, mode="cover", passes=3, delay=0.0008)
    _showing["on"] = True
    _reader["pages"] = None


def back_to_face(peer):
    """Drop any image/reader page and repaint the face/chat console."""
    _reader["pages"] = None
    if _showing["on"] and show_image is not None:
        with _disp_lock:
            show_image.exit_graphics(_disp, peer)    # sends U (repaint the console)
        _showing["on"] = False
        time.sleep(0.4)


# ---- the talking face: speak each answer on the dev PC (Windows SAPI), and
# flap the portrait's mouth on the old PC's screen while it speaks ----
# One worker thread plays queued answers in order so they never overlap; text is
# piped in via stdin so punctuation never breaks the command. Disable with
# AGENTZERO_TTS=0. Non-Windows hosts just skip it.
try:
    import face_anim                             # mouth animation over UDP (no cycle)
except Exception:
    face_anim = None
_anim_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
_last_peer = [None]                              # the old PC's IP (set per question)
_tts_q = queue.Queue(maxsize=4)
_TTS_ON = os.environ.get("AGENTZERO_TTS", "1") != "0" and sys.platform == "win32"
# Pick an English voice (the OS default is the system-locale voice - German here,
# which mangles English). Override with AGENTZERO_VOICE="Microsoft Zira Desktop".
_PS_SPEAK = (
    "Add-Type -AssemblyName System.Speech;"
    "$v=New-Object System.Speech.Synthesis.SpeechSynthesizer;"
    "$want=$env:AGENTZERO_VOICE;"
    "if($want){try{$v.SelectVoice($want)}catch{}}"
    "else{$en=$v.GetInstalledVoices()|"
    "?{$_.Enabled -and $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'en'}|"
    "Select-Object -First 1; if($en){$v.SelectVoice($en.VoiceInfo.Name)}}"
    "$v.Rate=1;$v.Speak([Console]::In.ReadToEnd())")


def _tts_worker():
    while True:
        text = _tts_q.get()
        peer = _last_peer[0]
        stop = threading.Event()
        flap_t = None
        if face_anim and peer:                   # flap the mouth while it speaks
            flap_t = threading.Thread(target=face_anim.flap,
                                      args=(_anim_sock, peer, stop), daemon=True)
            flap_t.start()
        try:
            subprocess.run(["powershell", "-NoProfile", "-Command", _PS_SPEAK],
                           input=text, text=True, timeout=90,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            print("tts error (ignored): %r" % e, flush=True)
        finally:
            stop.set()                           # stop flapping, close the mouth
            if flap_t:
                flap_t.join(timeout=1.5)
            _tts_q.task_done()


def speak(text):
    if not _TTS_ON or not text:
        return
    try:
        _tts_q.put_nowait(text[:400])            # cap length; drop if the queue is full
    except queue.Full:
        pass


def main():
    if _TTS_ON:
        threading.Thread(target=_tts_worker, daemon=True).start()
        print("talking face: TTS on (AGENTZERO_TTS=0 to mute)", flush=True)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", Q_PORT))
    # Windows: a prior UDP sendto to a closed port makes the NEXT recvfrom raise
    # WinError 10054 (ICMP port-unreachable). Disable that behaviour so the old
    # PC's ICMP replies can never crash the service.
    try:
        SIO_UDP_CONNRESET = 0x9800000C
        s.ioctl(SIO_UDP_CONNRESET, 0)           # not supported on all Pythons
    except Exception:
        pass                                     # recvfrom try/except below is the real guard
    print("agent_chat listening on udp :%d (questions), replying to :%d" % (Q_PORT, R_PORT), flush=True)
    last = {"key": None, "a": None, "t": 0.0}    # dedup repeated packets (kernel sends twice)
    while True:
        try:
            data, addr = s.recvfrom(2048)
        except ConnectionResetError:
            continue                             # ICMP unreachable from a prior reply - ignore
        except OSError as e:
            print("recv error (ignored): %r" % e, flush=True)
            continue
        try:
            q = data.decode("latin1", "replace")
            print("Q from %s:%d  (%d bytes): %r" % (addr[0], addr[1], len(data), q), flush=True)
            peer = addr[0]
            _last_peer[0] = peer                 # the old PC, for the talking-face mouth
            low = q.strip().lower()

            # --- reader navigation: a parsed page is up; each keystroke arrives alone
            # (the kernel sends per-key while a page is shown). Move a cursor over the
            # links, follow the selected one, page, or quit. ---
            if _reader["pages"] is not None and webread is not None:
                ch = q[:1].lower()
                seq = q[1] if len(q) >= 2 else None   # dedup the kernel's redundant copies
                if seq is not None and seq == _kseq["v"]:
                    continue
                _kseq["v"] = seq
                if ch == "j":                        # cursor down (next link)
                    _move_cursor(peer, +1)
                elif ch == "k":                      # cursor up (prev link)
                    _move_cursor(peer, -1)
                elif ch in (" ", "f", "g"):          # follow the selected link
                    if _reader["sel"] is not None:
                        open_url(peer, _reader["links"][_reader["sel"]]["url"])
                elif ch == "n":                      # next page
                    if _reader["cur"] < len(_reader["pages"]) - 1:
                        _reader["cur"] += 1; _blit_page(peer)
                elif ch == "p":                      # previous page
                    if _reader["cur"] > 0:
                        _reader["cur"] -= 1; _blit_page(peer)
                elif ch == "q":                      # quit back to the face
                    back_to_face(peer)
                continue                             # reader mode consumes every key

            # --- web/read <domain> -> parse the page and show it (text + images + links) ---
            verb = next((v for v in WEB_VERBS if low.startswith(v)), None)
            if verb and webread is not None:
                target = q.split(None, 1)[1].strip() if len(q.split(None, 1)) > 1 else ""
                if target:
                    if not open_url(peer, target):
                        back_to_face(peer)
                        _send_text(s, peer, "could not load " + target)
                    continue

            # --- shot/pic <domain> -> full-page screenshot (not reflowed) ---
            verb = next((v for v in SHOT_VERBS if low.startswith(v)), None)
            if verb and show_image is not None and webshot is not None:
                target = q.split(None, 1)[1].strip() if len(q.split(None, 1)) > 1 else ""
                if target:
                    try:
                        show_shot(peer, target)
                    except Exception as e:
                        print("webshot error: %r" % e, flush=True)
                        back_to_face(peer)
                        _send_text(s, peer, "could not load " + target)
                    continue

            # --- any other input while an image/page is up: return to the face first ---
            if _showing["on"]:
                back_to_face(peer)
                if low in ("", "back", "face", "home", "weiter", "zurueck", "zuruck", "ok"):
                    continue                     # just go back to the face, no answer text

            # --- normal Q&A ---
            key = (peer, q)
            now = time.time()
            if key == last["key"] and now - last["t"] < 4.0:
                a = last["a"]                    # duplicate within 4s: reuse, don't re-ask the LLM
            else:
                a = answer(q)
                last.update(key=key, a=a, t=now)
                speak(a)                         # the talking face reads new answers aloud
            _send_text(s, peer, a, q)
            print("A -> %s:%d : %r" % (peer, R_PORT, a), flush=True)
        except Exception as e:                   # never let one bad packet kill the loop
            print("handler error (ignored): %r" % e, flush=True)


if __name__ == "__main__":
    main()
