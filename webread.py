#!/usr/bin/env python3
# webread.py - read a web page's CONTENT (not a screenshot): fetch it, pull out the
# title, text, images and links, and lay them out as clean "reader" pages (1024x768
# bitmaps) for the AgentZero bare-metal framebuffer. Links are numbered so they can
# be followed by typing the number on the machine's own keyboard.
#
# Returns (pages, links): pages is a list of PIL Images (framebuffer-sized), links is
# a list of absolute URLs (index N == the [N] shown on screen).
#
#   python webread.py <url> [outdir]      # dev test: render pages to PNGs
import io, os, re, sys, urllib.parse, urllib.request

from PIL import Image, ImageDraw, ImageFont

W, H = 1024, 768
MARGIN = 40
CONTENT_W = W - 2 * MARGIN
BG = (248, 248, 246)
FG = (20, 20, 20)
GRAY = (110, 110, 110)
LINK = (20, 90, 200)
HR = (210, 210, 205)
FONTS = r"C:\Windows\Fonts"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def _font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONTS, name), size)
    except OSError:
        return ImageFont.load_default()


F_TITLE = _font("arialbd.ttf", 34)
F_H = _font("arialbd.ttf", 24)
F_BODY = _font("arial.ttf", 20)
F_LINK = _font("arial.ttf", 20)
F_CAP = _font("arial.ttf", 15)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read()
        ctype = r.headers.get("Content-Type", "")
        final = r.geturl()
    m = re.search(r"charset=([\w-]+)", ctype, re.I)
    enc = m.group(1) if m else "utf-8"
    try:
        return raw.decode(enc, "replace"), final
    except LookupError:
        return raw.decode("utf-8", "replace"), final


def parse(html, base):
    """Extract an ordered list of blocks + a numbered link list."""
    from bs4 import BeautifulSoup
    soup = BeautifulSoup(html, "html.parser")
    for t in soup(["script", "style", "noscript", "nav", "footer", "header",
                   "aside", "form", "svg", "button"]):
        t.decompose()
    title = (soup.title.string.strip() if soup.title and soup.title.string else "")
    # pick the densest main container, else body
    root = soup.find("article") or soup.find("main") or soup.body or soup
    blocks, links = [], []

    def add_text(tag, kind):
        txt = " ".join(tag.get_text(" ", strip=True).split())
        if txt:
            blocks.append((kind, txt))

    seen_img = set()
    for el in root.find_all(["h1", "h2", "h3", "p", "li", "img"], recursive=True):
        if el.name == "img":
            src = el.get("src") or el.get("data-src") or ""
            if not src or src.startswith("data:"):
                continue
            src = urllib.parse.urljoin(base, src)
            if src.lower().endswith(".svg") or src in seen_img:
                continue
            seen_img.add(src)
            blocks.append(("img", (src, (el.get("alt") or "").strip())))
        elif el.name in ("h1", "h2", "h3"):
            add_text(el, "h")
        else:
            add_text(el, "p")
    # collect links (deduped, in order) from the main content
    for a in root.find_all("a", href=True):
        href = urllib.parse.urljoin(base, a["href"])
        txt = " ".join(a.get_text(" ", strip=True).split())
        if (txt and href.startswith("http") and "#" not in href[:8]
                and href not in [u for _, u in links]):
            links.append((txt[:60], href))
            if len(links) >= 40:
                break
    return title, blocks, links


MAX_IMAGES = 8                     # cap downloads so image-heavy news pages stay fast


def _dl_image(src):
    try:
        req = urllib.request.Request(src, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=6) as r:
            data = r.read(3_000_000)              # cap size; avoid huge downloads
        im = Image.open(io.BytesIO(data)).convert("RGB")
        if im.width < 80 or im.height < 60:       # skip icons / spacers
            return None
        return im
    except Exception:
        return None


class Pager:
    """Lay blocks out top-to-bottom, spilling onto new 1024x768 pages."""
    def __init__(self):
        self.pages = []
        self._new()

    def _new(self):
        self.img = Image.new("RGB", (W, H), BG)
        self.d = ImageDraw.Draw(self.img)
        self.y = MARGIN
        self.pages.append(self.img)

    def _space(self, need):
        if self.y + need > H - MARGIN:
            self._new()

    def wrap(self, text, font):
        words, lines, cur = text.split(), [], ""
        for w in words:
            t = (cur + " " + w).strip()
            if self.d.textlength(t, font=font) <= CONTENT_W:
                cur = t
            else:
                if cur:
                    lines.append(cur)
                cur = w
        if cur:
            lines.append(cur)
        return lines or [""]

    def text(self, s, font, color, lh, gap=6):
        for ln in self.wrap(s, font):
            self._space(lh)
            self.d.text((MARGIN, self.y), ln, font=font, fill=color)
            self.y += lh
        self.y += gap

    def image(self, im, caption):
        scale = min(1.0, (CONTENT_W) / im.width, 460 / im.height)
        w, h = max(1, int(im.width * scale)), max(1, int(im.height * scale))
        im = im.resize((w, h), Image.LANCZOS)
        self._space(h + 24)
        x = MARGIN + (CONTENT_W - w) // 2
        self.img.paste(im, (x, self.y))
        self.y += h + 4
        if caption:
            self.text(caption, F_CAP, GRAY, 18, gap=8)
        else:
            self.y += 8

    def rule(self):
        self._space(16)
        self.d.line((MARGIN, self.y, W - MARGIN, self.y), fill=HR, width=1)
        self.y += 14


MAX_CONTENT_PAGES = 10             # cap a long article so it stays navigable on bare metal


def render(url):
    html, base = fetch(url)
    title, blocks, links = parse(html, base)
    pg = Pager()
    host = urllib.parse.urlparse(base).netloc
    pg.text(host, F_CAP, GRAY, 18, gap=2)
    if title:
        pg.text(title, F_TITLE, FG, 42, gap=10)
    pg.rule()
    nimg = 0
    for kind, val in blocks:
        if len(pg.pages) > MAX_CONTENT_PAGES:
            pg.text("...", F_BODY, GRAY, 27, gap=6)
            break
        if kind == "h":
            pg.y += 6
            pg.text(val, F_H, FG, 30, gap=6)
        elif kind == "p":
            pg.text(val, F_BODY, FG, 27, gap=10)
        elif kind == "img" and nimg < MAX_IMAGES:
            nimg += 1
            im = _dl_image(val[0])
            if im is not None:
                pg.image(im, val[1])
    # links section - one link per line, with each line's page + y recorded so the
    # dev PC can draw a movable cursor and follow the selected link.
    links_meta = []
    if links:
        pg.rule()
        pg._space(34)
        pg.d.text((MARGIN, pg.y), "Links   move: j / k    open: space    page: n / p    back: q",
                  font=F_H, fill=FG)
        pg.y += 38
        for i, (txt, href) in enumerate(links, 1):
            pg._space(30)
            lp = len(pg.pages) - 1
            y0 = int(pg.y)
            s = "[%d] %s" % (i, txt)
            while pg.d.textlength(s, font=F_LINK) > CONTENT_W and len(s) > 5:
                s = s[:-2]
            pg.d.text((MARGIN, pg.y), s, font=F_LINK, fill=LINK)
            pg.y += 30
            links_meta.append({"url": href, "text": txt, "page": lp, "y0": y0, "y1": y0 + 28})
    return pg.pages, links_meta


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python webread.py <url> [outdir]")
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    pages, links = render(sys.argv[1])
    for i, p in enumerate(pages):
        fn = os.path.join(outdir, "webread_%02d.png" % i)
        p.save(fn)
        print(fn)
    print("%d page(s), %d links" % (len(pages), len(links)))
