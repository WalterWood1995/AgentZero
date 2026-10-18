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
import socket
import sys
import textwrap
import time

Q_PORT = 50001          # we listen here (questions from the old PC)
R_PORT = 50000          # kernel listens here (display commands)
LEFT_W = 38             # left dialogue column width (face is on the right)

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
        _client = anthropic.Anthropic(api_key=key, default_headers=headers or None)
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


def main():
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
            key = (addr[0], q)
            now = time.time()
            if key == last["key"] and now - last["t"] < 4.0:
                a = last["a"]                    # duplicate within 4s: reuse, don't re-ask the LLM
            else:
                a = answer(q)
                last.update(key=key, a=a, t=now)
            # build left-column lines: question then wrapped answer
            lines = ["Q: " + q][:1]
            for ln in textwrap.wrap("A: " + a, LEFT_W) or ["A:"]:
                lines.append(ln)
            lines = lines[:44]
            # one block write, each line padded to clear the left column (not the face)
            payload = "B00\n" + "\n".join(l.ljust(40)[:40] for l in lines)
            for _ in range(4):                   # fire-and-forget with redundancy
                s.sendto(payload.encode("latin1"), (addr[0], R_PORT))
            print("A -> %s:%d  (%d lines): %r" % (addr[0], R_PORT, len(lines), a), flush=True)
        except Exception as e:                   # never let one bad packet kill the loop
            print("handler error (ignored): %r" % e, flush=True)


if __name__ == "__main__":
    main()
