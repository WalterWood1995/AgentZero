#!/usr/bin/env python3
# agent_chat.py - dev-PC side of the AgentZero chat terminal.
# The old PC sends the typed question here over UDP (port 50001); we answer and
# send the text back to the old PC's screen (port 50000) as kernel display
# commands (left column, the face stays on the right). This placeholder just
# echoes / canned-answers; swap `answer()` for a real LLM backend later.
import socket
import sys
import textwrap

Q_PORT = 50001          # we listen here (questions from the old PC)
R_PORT = 50000          # kernel listens here (display commands)
LEFT_W = 38             # left dialogue column width (face is on the right)


INTRO = (
    "I am AgentZero. This old Asus has no OS and no "
    "software - just a tiny bare-metal kernel at ring 0 "
    "that an AI agent drives over the network. You type "
    "here; the keystrokes leave the machine as raw UDP; "
    "the agent answers and paints the text straight into "
    "video memory. Likely the first netbook on Earth run "
    "by an agent and skills alone - no operating system."
)


def answer(q):
    q = q.strip()
    if not q:
        return "..."
    low = q.lower()
    if low in ("hi", "hello", "hey"):
        return "Hello. I am AgentZero, running on bare metal, ring 0, no OS. Ask me to introduce myself."
    # any introduce / who-are-you / what-is style question -> the AgentZero intro
    if ("intro" in low or "introduc" in low or "介绍" in q
            or "who" in low or "what is" in low or "about" in low
            or "agentzero" in low or "agent zero" in low):
        return INTRO
    # placeholder: echo until a real LLM backend is wired in
    return "You said: " + q


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
            a = answer(q)
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
