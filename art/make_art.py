"""Phantom Pact release art (cover, banner, logo).

Style matches the Blood Pact Nexus banner: Georgia Bold ivory caps with a dark
drop shadow and crimson under-shadow, a thin crimson rule, Georgia Italic subtitle.
Re-run:  python -I make_art.py [path-to-key-art]
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SRC = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Temp", "claude",
    "C--Users-TheCo-Downloads-Coop-Mode---Onimusha-Way-of-the-Sword",
    "b4c3cbaa-e026-4a6f-a134-4622b5466edb", "images", "1.webp")
SRC = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC

FONTS = r"C:\Windows\Fonts"
BOLD = os.path.join(FONTS, "georgiab.ttf")
ITAL = os.path.join(FONTS, "georgiai.ttf")
REG = os.path.join(FONTS, "georgia.ttf")

IVORY = (240, 228, 204)
CRIMSON = (178, 24, 30)
SOFT = (222, 214, 198)


def font(path, size):
    return ImageFont.truetype(path, size)


def text_w(draw, s, f, spacing=0):
    if spacing == 0:
        return draw.textlength(s, font=f)
    return sum(draw.textlength(c, font=f) for c in s) + spacing * (len(s) - 1)


def draw_spaced(draw, xy, s, f, fill, spacing=0):
    x, y = xy
    if spacing == 0:
        draw.text((x, y), s, font=f, fill=fill)
        return
    for c in s:
        draw.text((x, y), c, font=f, fill=fill)
        x += draw.textlength(c, font=f) + spacing


def title_layer(size, items):
    """items: list of (x, y, text, font, spacing, style) where style in
    'title' | 'sub' | 'small'.  Returns RGBA layer with shadows + glow."""
    W, H = size
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    red = Image.new("RGBA", size, (0, 0, 0, 0))
    face = Image.new("RGBA", size, (0, 0, 0, 0))
    gd, sd, rd, fd = (ImageDraw.Draw(i) for i in (glow, shadow, red, face))
    for x, y, s, f, sp, style in items:
        px = max(2, int(f.size * 0.035))
        if style == "title":
            draw_spaced(gd, (x, y), s, f, (0, 0, 0, 255), sp)
            draw_spaced(rd, (x + px, y + px), s, f, CRIMSON + (255,), sp)
            draw_spaced(sd, (x + px * 2, y + px * 2), s, f, (0, 0, 0, 230), sp)
            draw_spaced(fd, (x, y), s, f, IVORY + (255,), sp)
        else:
            draw_spaced(gd, (x, y), s, f, (0, 0, 0, 255), sp)
            draw_spaced(sd, (x + px, y + px), s, f, (0, 0, 0, 220), sp)
            draw_spaced(fd, (x, y), s, f, (SOFT if style == "small" else IVORY) + (255,), sp)
    big = max(i[3].size for i in items)
    glow = glow.filter(ImageFilter.GaussianBlur(big * 0.18))
    # strengthen glow (dark halo for legibility on busy ink background)
    a = glow.getchannel("A").point(lambda v: min(255, int(v * 1.6)))
    glow.putalpha(a)
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(1, big * 0.012)))
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    for layer in (glow, shadow, red, face):
        out = Image.alpha_composite(out, layer)
    return out


def rule(draw, x0, x1, y, h):
    draw.rectangle([x0, y, x1, y + h], fill=CRIMSON + (255,))


def block(draw_probe, scale, left_x, top_y, align="left", width=None):
    """Lay out the Phantom Pact lockup. Returns (items, rules, bbox)."""
    ft = font(BOLD, int(150 * scale))
    fs = font(BOLD, int(46 * scale))
    fi = font(ITAL, int(34 * scale))
    sp_t = int(6 * scale)
    sp_s = int(9 * scale)
    lines = []
    y = top_y
    w1 = text_w(draw_probe, "PHANTOM", ft, sp_t)
    w2 = text_w(draw_probe, "PACT", ft, sp_t)
    ws = text_w(draw_probe, "2-PLAYER ONLINE CO-OP", fs, sp_s)
    wi = text_w(draw_probe, "for Phantom Blade Zero  \u2022  Fan-made", fi)
    full = width or max(w1, w2, ws, wi)

    def xpos(w):
        return left_x + (full - w) / 2 if align == "center" else left_x

    items = [
        (xpos(w1), y, "PHANTOM", ft, sp_t, "title"),
        (xpos(w2), y + int(150 * scale), "PACT", ft, sp_t, "title"),
    ]
    ry = y + int(330 * scale)
    rw = max(w1, ws) if align == "center" else ws
    rules = [(xpos(rw), xpos(rw) + rw, ry, max(2, int(4 * scale)))]
    items.append((xpos(ws), ry + int(26 * scale), "2-PLAYER ONLINE CO-OP", fs, sp_s, "sub"))
    items.append((xpos(wi), ry + int(96 * scale),
                  "for Phantom Blade Zero  \u2022  Fan-made", fi, 0, "small"))
    return items, rules


def render_lockup(size, items, rules):
    layer = title_layer(size, items)
    # rule with a soft dark shadow
    rl = Image.new("RGBA", size, (0, 0, 0, 0))
    rd = ImageDraw.Draw(rl)
    for x0, x1, y, h in rules:
        rd.rectangle([x0 + 2, y + 2, x1 + 2, y + h + 2], fill=(0, 0, 0, 200))
    rl = rl.filter(ImageFilter.GaussianBlur(2))
    rd = ImageDraw.Draw(rl)
    for r in rules:
        rule(rd, *r)
    return Image.alpha_composite(rl, layer)


def vignette(size, cx, cy, rx, ry, strength):
    """Dark radial patch to boost text contrast."""
    W, H = size
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=int(255 * strength))
    m = m.filter(ImageFilter.GaussianBlur(min(rx, ry) * 0.45))
    dark = Image.new("RGBA", size, (8, 10, 9, 255))
    dark.putalpha(m)
    return dark


def make_cover(src):
    W, H = src.size
    img = src.convert("RGBA")
    img = Image.alpha_composite(img, vignette(img.size, 330, 330, 560, 420, 0.55))
    probe = ImageDraw.Draw(img)
    items, rules = block(probe, 0.94, 70, 64)
    img = Image.alpha_composite(img, render_lockup(img.size, items, rules))
    # Paste the untouched bottom-centre credit region back, so S-GAME logo and
    # copyright stay pixel-identical to the original.
    box = (380, 1720, 1580, H)
    img.paste(src.convert("RGBA").crop(box), box[:2])
    return img.convert("RGB")


def make_banner(src):
    W, H = 1920, 480
    bg_col = (20, 22, 20)
    out = Image.new("RGBA", (W, H), bg_col + (255,))
    s = 1120 / src.width
    art = src.convert("RGBA").resize((1120, round(src.height * s)), Image.LANCZOS)
    crop = art.crop((230, 40, 1120, 40 + H))  # hat + face + sword hilt
    ax = W - crop.width
    # fade the left edge of the art into the background
    fade = Image.new("L", crop.size, 255)
    fd = ImageDraw.Draw(fade)
    fw = 360
    for i in range(fw):
        fd.line([(i, 0), (i, H)], fill=int(255 * (i / fw) ** 1.4))
    crop.putalpha(fade)
    out.alpha_composite(crop, (ax, 0))
    # subtle top/bottom darkening
    g = Image.new("L", (1, H))
    for y in range(H):
        t = abs(y - H / 2) / (H / 2)
        g.putpixel((0, y), int(140 * max(0, t - 0.55) / 0.45))
    edge = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    edge.putalpha(g.resize((W, H)))
    out = Image.alpha_composite(out, edge)
    probe = ImageDraw.Draw(out)
    # wide lockup: title on one line
    ft = font(BOLD, 112)
    fs = font(BOLD, 40)
    fi = font(ITAL, 30)
    t = "PHANTOM PACT"
    tw = text_w(probe, t, ft, 6)
    sub = "2-PLAYER ONLINE CO-OP"
    sw = text_w(probe, sub, fs, 8)
    small = "for Phantom Blade Zero  \u2022  Fan-made"
    iw = text_w(probe, small, fi)
    cx = 590
    items = [
        (cx - tw / 2, 74, t, ft, 6, "title"),
        (cx - sw / 2, 252, sub, fs, 8, "sub"),
        (cx - iw / 2, 318, small, fi, 0, "small"),
    ]
    rw = tw * 0.62
    rules = [(cx - rw / 2, cx + rw / 2, 222, 4)]
    out = Image.alpha_composite(out, render_lockup((W, H), items, rules))
    d = ImageDraw.Draw(out)
    fc = font(ITAL, 20)
    credit = "Key art \u00a9 2026 SGAME STUDIO Limited"
    d.text((W - 24 - d.textlength(credit, font=fc), H - 34), credit, font=fc,
           fill=(200, 194, 182, 200))
    return out.convert("RGB")


def make_logo():
    size = (2000, 900)
    probe = ImageDraw.Draw(Image.new("RGBA", size))
    items, rules = block(probe, 1.6, 0, 40, align="center")
    # centre horizontally
    ft_w = max(text_w(probe, it[2], it[3], it[4]) + it[0] for it in items)
    dx = (size[0] - ft_w) / 2
    items = [(x + dx, y, s, f, sp, st) for x, y, s, f, sp, st in items]
    rules = [(a + dx, b + dx, y, h) for a, b, y, h in rules]
    img = render_lockup(size, items, rules)
    return img.crop(img.getbbox())


# --------------------------------------------------------------------------
# "Online Multiplayer" card + 1300x372 banner, mirroring the Blood Pact
# 08-online-multiplayer-card / 00-banner-1300x372 layouts: the hero twice,
# warm copy left, mirrored cool blue-violet copy right, dark centre seam.
# PBZ's swordsman faces left in the key art, so the LEFT copy is the mirrored
# one and the right copy is the original, so both face the centre.
# --------------------------------------------------------------------------
GOLD = (214, 182, 128)
DEEP_RED = (120, 14, 18)


def cool_tint(img):
    """Desaturated blue-violet grade (the 'player 2' look)."""
    from PIL import ImageOps, ImageEnhance
    rgb = img.convert("RGB")
    lum = ImageOps.grayscale(rgb)
    tinted = ImageOps.colorize(lum, black=(6, 6, 20), mid=(92, 94, 140),
                               white=(226, 228, 255))
    out = Image.blend(ImageEnhance.Color(rgb).enhance(0.35), tinted, 0.62)
    return ImageEnhance.Brightness(out).enhance(1.06).convert("RGBA")


def twin_background(src, W, H, box, overlap):
    """box = crop of the source around hat+face (face near the left of box).
    Returns W x H RGBA: mirrored warm copy left, cool original right."""
    half = W // 2 + overlap
    crop = src.convert("RGBA").crop(box).resize((half, H), Image.LANCZOS)
    left = crop.transpose(Image.FLIP_LEFT_RIGHT)
    right = cool_tint(crop)
    out = Image.new("RGBA", (W, H), (10, 10, 12, 255))
    # each half fades out toward the seam
    def fade(img, toward_right):
        m = Image.new("L", (half, 1))
        for x in range(half):
            d = (half - 1 - x) if toward_right else x  # distance from seam side
            m.putpixel((x, 0), int(255 * min(1.0, d / (overlap * 2.2)) ** 0.9))
        img = img.copy()
        img.putalpha(m.resize((half, H)))
        return img
    out.alpha_composite(fade(left, True), (0, 0))
    out.alpha_composite(fade(right, False), (W - half, 0))
    # dark centre seam
    seam = Image.new("L", (W, 1))
    for x in range(W):
        t = abs(x - W / 2) / (W * 0.22)
        seam.putpixel((x, 0), int(200 * max(0.0, 1 - t) ** 1.6))
    dark = Image.new("RGBA", (W, H), (6, 6, 8, 255))
    dark.putalpha(seam.resize((W, H)))
    out = Image.alpha_composite(out, dark)
    # gentle overall vignette
    vg = Image.new("L", (W, H), 0)
    ImageDraw.Draw(vg).rectangle([0, 0, W, H], outline=255, width=int(min(W, H) * 0.06))
    vg = vg.filter(ImageFilter.GaussianBlur(min(W, H) * 0.09))
    vd = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    vd.putalpha(vg.point(lambda v: int(v * 0.7)))
    return Image.alpha_composite(out, vd)


def card_text(size, items):
    """items: (cx, y, text, font, spacing, kind) centred on cx.
    kind: 'hero' ivory + crimson offset, 'gold', 'italic'."""
    W, H = size
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    halo = Image.new("RGBA", size, (0, 0, 0, 0))
    soft = Image.new("RGBA", size, (0, 0, 0, 0))
    hard = Image.new("RGBA", size, (0, 0, 0, 0))
    hd, sd, kd = ImageDraw.Draw(halo), ImageDraw.Draw(soft), ImageDraw.Draw(hard)
    face = Image.new("RGBA", size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(face)
    big = 1
    for cx, y, s, f, sp, kind in items:
        x = cx - text_w(probe, s, f, sp) / 2
        o = max(2, round(f.size * 0.045))
        big = max(big, f.size)
        draw_spaced(hd, (x, y), s, f, (0, 0, 0, 255), sp)
        draw_spaced(sd, (x + o * 0.6, y + o * 0.9), s, f, (0, 0, 0, 235), sp)
        if kind == "hero":
            draw_spaced(kd, (x + o, y + o), s, f, DEEP_RED + (255,), sp)
            col = IVORY
        elif kind == "gold":
            col = GOLD
        else:
            col = SOFT
        draw_spaced(fd, (x, y), s, f, col + (255,), sp)
    halo = halo.filter(ImageFilter.GaussianBlur(big * 0.22))
    halo.putalpha(halo.getchannel("A").point(lambda v: int(min(255, v * 1.1) * 0.75)))
    soft = soft.filter(ImageFilter.GaussianBlur(max(1.5, big * 0.03)))
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    for layer in (halo, soft, hard, face):
        out = Image.alpha_composite(out, layer)
    return out


def red_rule(img, x0, x1, y, h):
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.rectangle([x0 + 1, y + 2, x1 + 1, y + h + 2], fill=(0, 0, 0, 200))
    lay = lay.filter(ImageFilter.GaussianBlur(1.5))
    d = ImageDraw.Draw(lay)
    d.rectangle([x0, y, x1, y + h], fill=(176, 26, 30, 255))
    return Image.alpha_composite(img, lay)


def credit_line(img, text, size, xy=None, align="center"):
    d = ImageDraw.Draw(img)
    f = font(ITAL, size)
    w = d.textlength(text, font=f)
    W, H = img.size
    if xy is None:
        xy = ((W - w) / 2, H - size - 14)
    elif align == "right":
        xy = (xy[0] - w, xy[1])
    d.text((xy[0] + 1, xy[1] + 1), text, font=f, fill=(0, 0, 0, 220))
    d.text(xy, text, font=f, fill=(196, 190, 178, 230))


def make_mp_card(src):
    W, H = 1920, 1080
    # face (~1000,650 in source) sits ~40% into this box -> after the mirror it
    # lands ~1/3 in from the outer edge, as in the Blood Pact card.
    box = (298, 100, 1378, 1190)         # 1080 x 1090 ~ (960+overlap) x 1080
    img = twin_background(src, W, H, box, overlap=110)
    cx = W / 2
    items = [
        (cx, 296, "PHANTOM PACT", font(BOLD, 46), 2, "gold"),
        (cx, 372, "ONLINE", font(BOLD, 112), 3, "hero"),
        (cx, 520, "MULTIPLAYER", font(BOLD, 112), 3, "hero"),
        (cx, 702, "Phantom Blade Zero  -  2 players", font(ITAL, 34), 1, "italic"),
    ]
    img = Image.alpha_composite(img, card_text((W, H), items))
    img = red_rule(img, cx - 300, cx + 300, 680, 3)
    credit_line(img, "Key art © 2026 SGAME STUDIO Limited  •  Fan-made mod", 20)
    return img.convert("RGB")


def make_banner_1300(src):
    W, H = 1300, 372
    box = (215, 160, 1455, 810)          # 1240 x 650 ~ 710 x 372: hat + face
    img = twin_background(src, W, H, box, overlap=60)
    cx = W / 2
    items = [
        (cx, 12, "PHANTOM PACT", font(BOLD, 86), 2, "hero"),
        (cx, 118, "Online Co-op for Phantom Blade Zero", font(REG, 27), 0, "italic"),
    ]
    img = Image.alpha_composite(img, card_text((W, H), items))
    img = red_rule(img, cx - 210, cx + 210, 104, 3)
    credit_line(img, "by TheCodesAreReal", 19, (W - 16, H - 32), align="right")
    credit_line(img, "Key art © 2026 SGAME STUDIO Limited", 15, (16, H - 28))
    return img.convert("RGB")


def main():
    src = Image.open(SRC)
    src.load()
    os.makedirs(HERE, exist_ok=True)
    make_mp_card(src).save(os.path.join(HERE, "phantom-pact-multiplayer-card.png"), optimize=True)
    make_banner_1300(src).save(os.path.join(HERE, "phantom-pact-banner-1300x372.png"), optimize=True)
    make_cover(src).save(os.path.join(HERE, "phantom-pact-cover.png"), optimize=True)
    make_banner(src).save(os.path.join(HERE, "phantom-pact-banner.png"), optimize=True)
    make_logo().save(os.path.join(HERE, "phantom-pact-logo.png"), optimize=True)
    print("done")


if __name__ == "__main__":
    main()
