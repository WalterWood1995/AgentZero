#!/usr/bin/env python3
# web.py - the AgentZero "browser" skill (dev-PC side).
#
# Fetch a web page, have Claude boil it down to a 40-column-screen digest, and
# paint it onto the old PC's AgentZero terminal (left column, face stays right).
#
# Two ways in:
#   - On the old PC's own keyboard, type:  web example.com
#     (agent_chat routes "web <domain>" questions here - all lowercase, a dot and
#      a space, so it needs no Shift/':'/'/' keys the kernel doesn't map yet)
#   - On the dev PC:  python web.py example.com   (fetches + pushes to the old PC)
#
# No module-level import of agent_chat, so agent_chat can import this one without
# a cycle; the client/ascii helper are passed in (or imported lazily in main()).
import re
import socket
import sys
import textwrap
import urllib.request

OLD_PC = "192.168.178.114"      # the AgentZero machine
R_PORT = 50000                  # its display port
LEFT_W = 38                     # left column width (face is on the right)
PANE_H = 14                     # pad to this many rows so it clears the previous reply

SUMMARY_SYS = (
    "You are AgentZero, summarizing a web page for a 40-column bare-metal text screen. "
    "Reply in plain ASCII only, at most ~55 words, just the key facts/answer - no preamble, "
    "no markdown. If the page is an error or empty, say so briefly."
)


def _norm_url(arg):
    arg = arg.strip()
    if arg.lower().startswith(("http://", "https://")):
        return arg
    return "https://" + arg


def fetch(url, limit=6000):
    """Fetch a URL and return crude plain text (title + visible body)."""
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (AgentZero; bare-metal) urllib",
        "Accept": "text/html,application/xhtml+xml",
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read(600000)
        enc = r.headers.get_content_charset() or "utf-8"
    html = raw.decode(enc, "replace")
    title = ""
    m = re.search(r"(?is)<title[^>]*>(.*?)</title>", html)
    if m:
        title = re.sub(r"\s+", " ", m.group(1)).strip()
    html = re.sub(r"(?is)<(script|style|noscript|head).*?</\1>", " ", html)
    text = re.sub(r"(?s)<[^>]+>", " ", html)
    text = re.sub(r"&[a-zA-Z#0-9]+;", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    if title:
        text = title + ". " + text
    return text[:limit]


def summarize(url, text, client, ascii_fn):
    """Claude digest of the page text, sized for the screen. Falls back to raw."""
    if client is None:
        return ascii_fn(text[:300])
    try:
        msg = client.messages.create(
            model=__import__("agent_chat").MODEL, max_tokens=300, system=SUMMARY_SYS,
            messages=[{"role": "user", "content": "URL: %s\n\nPage text:\n%s" % (url, text)}],
        )
        out = "".join(getattr(b, "text", "") for b in msg.content
                      if getattr(b, "type", "") == "text")
        return ascii_fn(" ".join(out.split())) or ascii_fn(text[:300])
    except Exception as e:
        return "web summarize error: %r" % e


def web_answer(arg, client, ascii_fn):
    """Fetch + summarize a page; return the digest string (used by agent_chat)."""
    url = _norm_url(arg)
    try:
        text = fetch(url)
    except Exception as e:
        return "Could not fetch %s (%s)" % (url, type(e).__name__)
    if not text:
        return "No readable text at %s" % url
    return summarize(url, text, client, ascii_fn)


def _lines_payload(title, body):
    lines = [title[:40]]
    for ln in textwrap.wrap(body, LEFT_W) or ["(empty)"]:
        lines.append(ln)
    lines = lines[:PANE_H]
    while len(lines) < PANE_H:                   # pad so it clears the previous reply
        lines.append("")
    return ("B00\n" + "\n".join(l.ljust(40)[:40] for l in lines)).encode("latin1")


def send_to_old_pc(title, body, host=OLD_PC):
    payload = _lines_payload(title, body)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _ in range(4):                       # fire-and-forget with redundancy
        s.sendto(payload, (host, R_PORT))


def main():
    if len(sys.argv) < 2:
        print("usage: python web.py <url-or-domain>  [old-pc-ip]")
        return
    arg = sys.argv[1]
    host = sys.argv[2] if len(sys.argv) > 2 else OLD_PC
    # lazy import here only (keeps agent_chat <-> web import one-directional)
    import agent_chat
    client = agent_chat._client_get()
    url = _norm_url(arg)
    print("fetching %s ..." % url, flush=True)
    summary = web_answer(arg, client, agent_chat._ascii)
    print("summary:", summary, flush=True)
    send_to_old_pc("WEB " + url.split("//", 1)[-1][:36], summary, host)
    print("sent to %s:%d" % (host, R_PORT), flush=True)


if __name__ == "__main__":
    main()
