"""Original layered app icon for XDM下载管理器 (2026-11-19).
Background: diagonal blue -> teal gradient. Foreground: one solid white download arrow flanked by two
translucent smaller arrows (parallel connections), all landing in a white tray.
Outputs (store-listing/icon/): background.png foreground.png (1024, layered), store-icon-1024.png,
store-icon-216.png (square full-bleed for AGC), startIcon.png (144, rounded), preview-1024.png (rounded).
usage: python scripts/make-icon.py"""
import os
from PIL import Image, ImageDraw
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'store-listing', 'icon')
S = 4  # supersampling
N = 1024 * S
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
def background():
    top, bot = (33, 120, 243), (0, 180, 160)
    g = Image.new('RGB', (256, 256))
    px = g.load()
    for y in range(256):
        for x in range(256):
            px[x, y] = lerp(top, bot, (x + y) / 510)
    return g.resize((1024, 1024), Image.BICUBIC)
def arrow(d, cx, top, w, h, fill):
    shaft = w * 0.42
    head_h = h * 0.42
    d.rounded_rectangle([cx - shaft / 2, top, cx + shaft / 2, top + h - head_h + 2], radius=shaft * 0.3, fill=fill)
    d.polygon([(cx - w / 2, top + h - head_h), (cx + w / 2, top + h - head_h), (cx, top + h)], fill=fill)
def foreground():
    img = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    lay = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    u = N / 1024
    side = (255, 255, 255, 140)
    arrow(d, 512 * u - 150 * u, 330 * u, 96 * u, 230 * u, side)
    arrow(d, 512 * u + 150 * u, 330 * u, 96 * u, 230 * u, side)
    img = Image.alpha_composite(img, lay)
    d = ImageDraw.Draw(img)
    arrow(d, 512 * u, 280 * u, 150 * u, 330 * u, (255, 255, 255, 255))
    # tray
    t = 34 * u
    x0, x1, y0, y1 = 300 * u, 724 * u, 600 * u, 720 * u
    d.rounded_rectangle([x0, y1 - t, x1, y1], radius=t / 2, fill='white')
    d.rounded_rectangle([x0, y0, x0 + t, y1], radius=t / 2, fill='white')
    d.rounded_rectangle([x1 - t, y0, x1, y1], radius=t / 2, fill='white')
    # enlarge the glyph ~15% about the centre (kept inside the layered-icon safe zone)
    c = int(N / 1.15)
    o = (N - c) // 2
    img = img.crop((o, o - int(10 * u), o + c, o + c - int(10 * u)))
    return img.resize((1024, 1024), Image.LANCZOS)
def rounded(im, size, r):
    im = im.resize((size * S, size * S), Image.LANCZOS)
    m = Image.new('L', im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, im.size[0] - 1, im.size[1] - 1], radius=r * S, fill=255)
    out = Image.new('RGBA', im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), m)
    return out.resize((size, size), Image.LANCZOS)
os.makedirs(OUT, exist_ok=True)
bg, fg = background(), foreground()
bg.save(os.path.join(OUT, 'background.png'))
fg.save(os.path.join(OUT, 'foreground.png'))
full = Image.alpha_composite(bg.convert('RGBA'), fg)
full.convert('RGB').save(os.path.join(OUT, 'store-icon-1024.png'))
full.convert('RGB').resize((216, 216), Image.LANCZOS).save(os.path.join(OUT, 'store-icon-216.png'))
rounded(full, 1024, 230).save(os.path.join(OUT, 'preview-1024.png'))
rounded(full, 144, 32).save(os.path.join(OUT, 'startIcon.png'))
print('ok', OUT)
