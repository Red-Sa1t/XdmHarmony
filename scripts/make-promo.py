"""Store promo screenshots for XDM下载管理器 (2026-11-19), same layout as the draw.io listing:
gradient background, app icon + name top-left, centred title + subtitle, app window below (bottom cropped).
Input: store-listing/raw/*.png (emulator 3120x2080, window at [515,281]-[2605,1675]); text is not edited.
Output: store-listing/screenshots-promo/{1920x1080,1280x720,800x450}/<NN-title>.png
usage: python scripts/make-promo.py"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'store-listing')
RAW = os.path.join(ROOT, 'raw')
OUT = os.path.join(ROOT, 'screenshots-promo')
FONT_BOLD = 'C:/Windows/Fonts/msyhbd.ttc'
FONT_REG = 'C:/Windows/Fonts/msyh.ttc'
WINDOW = (515, 281, 2605, 1675)  # app window bounds in the raw emulator capture
SHOTS = [
    ('01-active.png', '01-多线程下载', '多线程加速，断点续传', '分段并发下载，实时速度与剩余时间，暂停后随时继续'),
    ('02-finished.png', '02-分类管理', '下载完成，一目了然', '文档、音乐、视频、压缩包、程序自动分类'),
    ('03-progress.png', '03-下载进度', '进度清清楚楚', '已下载大小、速度、剩余时间实时显示，支持限速'),
    ('04-new-download.png', '04-浏览器接管', '浏览器一键接管', '配合浏览器扩展，点击下载链接即可交给本应用'),
    ('05-settings.png', '05-个性设置', '按你的习惯设置', '自定义接管的文件类型、视频格式与排除网站'),
]
W, H = 1920, 1080


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    top, bot = (40, 118, 236), (0, 170, 160)  # same hues as the app icon
    g = Image.new('RGB', (192, 108))
    px = g.load()
    for y in range(108):
        for x in range(192):
            px[x, y] = lerp(top, bot, (x / 192) * 0.55 + (y / 108) * 0.45)
    return g.resize((W, H), Image.BICUBIC)


def rounded_mask(size, r):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=r, fill=255)
    return m


def compose(raw_name, title, subtitle):
    img = background().convert('RGBA')
    d = ImageDraw.Draw(img)
    # brand: icon + name, top-left
    icon = Image.open(os.path.join(ROOT, 'icon', 'preview-1024.png')).convert('RGBA').resize((56, 56), Image.LANCZOS)
    img.alpha_composite(icon, (56, 40))
    d.text((126, 68), 'XDM下载管理器', font=ImageFont.truetype(FONT_BOLD, 30), fill='white', anchor='lm')
    # title + subtitle, centred
    d.text((W // 2, 122), title, font=ImageFont.truetype(FONT_BOLD, 66), fill='white', anchor='mm')
    d.text((W // 2, 192), subtitle, font=ImageFont.truetype(FONT_REG, 32), fill=(255, 255, 255, 235), anchor='mm')
    # app window, scaled to 1500 px wide, bottom cropped by the canvas edge
    win = Image.open(os.path.join(RAW, raw_name)).convert('RGBA').crop(WINDOW)
    ww = 1500
    wh = round(win.height * ww / win.width)
    win = win.resize((ww, wh), Image.LANCZOS)
    x, y = (W - ww) // 2, 250
    shadow = Image.new('RGBA', (ww + 80, wh + 80), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([40, 40, ww + 40, wh + 40], radius=22, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)), (x - 40, y - 28))
    framed = Image.new('RGBA', (ww, wh), (0, 0, 0, 0))
    framed.paste(win, (0, 0), rounded_mask((ww, wh), 18))
    img.alpha_composite(framed, (x, y))
    return img.convert('RGB')


for raw_name, out_name, title, subtitle in SHOTS:
    full = compose(raw_name, title, subtitle)
    for size in [(1920, 1080), (1280, 720), (800, 450)]:
        d = os.path.join(OUT, '%dx%d' % size)
        os.makedirs(d, exist_ok=True)
        (full if size == (W, H) else full.resize(size, Image.LANCZOS)).save(os.path.join(d, out_name + '.png'))
print('ok', OUT)
