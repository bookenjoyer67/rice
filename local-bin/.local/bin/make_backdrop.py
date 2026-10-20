#!/usr/bin/env python3
"""Build the lockscreen backdrop from the current wallpaper.

Grades the image so any wallpaper (bright stock photo or dark vapourwave) reads as
one moody surface: heavy blur, desaturated + darkened, tinted toward the palette
background, a soft accent bloom at the centre, and a vignette. swaylock then draws
only the ring + clock on top of it.

usage: make_backdrop.py <wallpaper> <out.png> [WxH]
Cache is the caller's job; this always renders.
"""
import sys
from PIL import Image, ImageChops, ImageEnhance, ImageFilter

# indicator radius as a fraction of the shorter screen side; lock.sh must use the
# same number for --indicator-radius so the baked halo sits under swaylock's ring.
R_IN = 0.2315


def hex_rgb(h, default):
    h = (h or default).lstrip("#")
    if len(h) == 8:
        h = h[:6]
    try:
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        return hex_rgb(default, default)


def palette(path):
    """Pull bg + accent from the matugen anchors yambar consumes."""
    vals = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(("c_bg:", "c_accent:")):
                    key, _, rest = line.partition(":")
                    quoted = rest.split('"')
                    if len(quoted) > 1:
                        vals[key.strip()] = quoted[1]
    except OSError:
        pass
    return hex_rgb(vals.get("c_bg"), "171216"), hex_rgb(vals.get("c_accent"), "f1b3e6")


def radial(size, inner, outer):
    """Square radial gradient by drawing concentric ellipse masks."""
    w, h = size
    mask = Image.new("L", (w, h), 0)
    steps = 256
    from PIL import ImageDraw
    d = ImageDraw.Draw(mask)
    cx, cy = w / 2, h / 2
    for i in range(steps, 0, -1):
        t = i / steps
        val = int(inner + (outer - inner) * (t ** 1.9))
        r = t * (max(w, h) / 2)
        d.ellipse([cx - r, cy - r * (h / w if w else 1), cx + r, cy + r * (h / w if w else 1)],
                  fill=val)
    return mask


def main():
    src, out = sys.argv[1], sys.argv[2]
    w, h = (int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else "1920x1080").split("x"))
    r_px = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
    bg, accent = palette(sys.argv[4] if len(sys.argv) > 4 else
                         f"{__import__('os').path.expanduser('~')}/.config/yambar/colors.yml")

    img = Image.open(src).convert("RGB")
    # cover-crop
    src_r = img.width / img.height
    dst_r = w / h
    if src_r > dst_r:
        new_w = int(img.height * dst_r)
        img = img.crop(((img.width - new_w) // 2, 0, (img.width + new_w) // 2, img.height))
    else:
        new_h = int(img.width / dst_r)
        img = img.crop((0, (img.height - new_h) // 2, img.width, (img.height + new_h) // 2))
    img = img.resize((w, h), Image.LANCZOS)

    # mood: heavy blur, less colour, darker
    img = img.filter(ImageFilter.GaussianBlur(radius=max(8, w // 110)))
    img = ImageEnhance.Color(img).enhance(0.45)
    img = ImageEnhance.Brightness(img).enhance(0.62)

    # tint toward the palette background so the lock matches the shell
    tint = Image.new("RGB", (w, h), bg)
    img = Image.blend(img, tint, 0.24)

    # vignette: darken the corners (mask 255 at centre -> 70 at the edges)
    vig = radial((w, h), 255, 96).filter(ImageFilter.GaussianBlur(radius=w // 40))
    img = ImageChops.multiply(img, Image.merge("RGB", (vig, vig, vig)))

    # accent bloom at the centre: screen a soft accent disc
    bloom = Image.new("RGB", (w, h), accent)
    bmask = radial((int(w * 0.75), int(h * 0.75)), 90, 0)
    bmask = bmask.filter(ImageFilter.GaussianBlur(radius=w // 30))
    hero = Image.new("RGB", (w, h), (0, 0, 0))
    hero.paste(bloom.resize((int(w * 0.75), int(h * 0.75))),
               ((w - int(w * 0.75)) // 2, (h - int(h * 0.75)) // 2),
               bmask)
    img = ImageChops.screen(img, hero)

    # Baked indicator halo: a soft accent annulus where swaylock draws its ring, so
    # the ring reads as light on the image instead of a vector stroke. R_IN is the
    # same fraction lock.sh uses for --indicator-radius, so they line up.
    from PIL import ImageDraw
    cx, cy = w / 2, h / 2
    r_in = r_px if r_px > 0 else min(w, h) * R_IN
    halo = Image.new("L", (w, h), 0)
    hd = ImageDraw.Draw(halo)
    for band, alpha in ((1.0, 150), (2.2, 90), (4.0, 45)):
        rr = r_in
        bw = max(2, int(r_in * 0.012 * band))
        hd.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=alpha, width=bw)
    halo = halo.filter(ImageFilter.GaussianBlur(radius=max(4, r_in * 0.045)))
    glow = Image.new("RGB", (w, h), accent)
    img = ImageChops.screen(img, Image.composite(glow, Image.new("RGB", (w, h), 0), halo))

    # darken inside the ring a touch so the clock reads on any wallpaper
    disc = Image.new("L", (w, h), 0)
    dd = ImageDraw.Draw(disc)
    dd.ellipse([cx - r_in * 0.98, cy - r_in * 0.98, cx + r_in * 0.98, cy + r_in * 0.98], fill=255)
    disc = disc.filter(ImageFilter.GaussianBlur(radius=r_in * 0.22))
    shade = Image.new("RGB", (w, h), (int(bg[0] * 0.35), int(bg[1] * 0.35), int(bg[2] * 0.35)))
    img = Image.composite(Image.blend(img, shade, 0.45), img, disc)

    img.save(out, "PNG", optimize=True)
    print(out)


if __name__ == "__main__":
    main()
