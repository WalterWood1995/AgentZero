#!/usr/bin/env python3
# webshot.py - screenshot a web page's homepage with headless Chrome/Edge, sized
# for the AgentZero framebuffer (default 1024x768). Used by agent_chat.py so the
# old PC's `web <domain>` command shows the page on-screen as an image.
#
#   python webshot.py example.com [out.png] [WxH]
import os, subprocess, sys, tempfile, time

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]


def _browser():
    for p in CHROME_CANDIDATES:
        if os.path.exists(p):
            return p
    raise RuntimeError("no Chrome/Edge found for screenshots")


def normalize(url):
    url = url.strip()
    if not url:
        raise ValueError("empty url")
    if "://" not in url:
        url = "https://" + url
    return url


def screenshot(url, out=None, w=1024, h=768, timeout=40):
    """Render url in headless Chrome and save a w x h PNG. Returns the path."""
    url = normalize(url)
    if out is None:
        out = os.path.join(tempfile.gettempdir(), "agentzero_webshot.png")
    # a throwaway profile dir avoids clashing with a running Chrome
    prof = tempfile.mkdtemp(prefix="azchrome_")
    cmd = [
        _browser(), "--headless=new", "--disable-gpu", "--no-sandbox",
        "--hide-scrollbars", "--disable-extensions",
        "--user-data-dir=" + prof,
        "--window-size=%d,%d" % (w, h),
        "--virtual-time-budget=8000",               # let the page settle ~8s
        "--screenshot=" + out, url,
    ]
    try:
        subprocess.run(cmd, timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        pass                                         # may still have written a frame
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        raise RuntimeError("screenshot failed for %s" % url)
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python webshot.py <url> [out.png] [WxH]")
    out = sys.argv[2] if len(sys.argv) > 2 else None
    w, h = 1024, 768
    if len(sys.argv) > 3 and "x" in sys.argv[3].lower():
        w, h = (int(v) for v in sys.argv[3].lower().split("x"))
    print(screenshot(sys.argv[1], out, w, h))
