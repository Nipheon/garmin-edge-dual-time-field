#!/usr/bin/env python3
"""Generate custom BMFont number fonts from Garmin_Roboto_Bold.ttf.

The Edge bitmap font set has a size canyon between FONT_NUMBER_MEDIUM (29px
digits) and FONT_NUMBER_HOT (42px digits), and tops out at 48px digits
(FONT_NUMBER_THAI_HOT) while native fields scale up to an 84px font in the
1-3 field layouts. Native firmware scales fonts continuously (vector fonts,
which Connect IQ does not expose on Edge devices), so to track native sizing
we bundle Roboto Bold rasterized at the in-between sizes.

Charset is numeric-only to keep the resource small: 0-9 . : -

Usage: python3 gen_number_fonts.py <output-dir> [<output-dir> ...]
Requires Pillow. Regenerate with:
  python3 tools/gen_number_fonts.py resources/fonts
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont

TTF = os.path.expanduser(
    "~/Library/Application Support/Garmin/ConnectIQ/Fonts/Garmin_Roboto_Bold.ttf")
CHARS = "0123456789.:-"
PAD = 1  # padding around each glyph in the atlas

# (name, target digit glyph height in px, xadvance trim in px)
FONTS = [
    ("number_mid", 34, 0),  # native small-slot value size (shrunk-to-width)
    ("number_xlg", 42, 0),  # native small-slot max digit size (short strings)
    ("number_lrg", 45, 0),  # large slots on 246x322-class devices (540/840/mtb)
    ("number_big", 60, 0),  # approximates the native 84px-font large layouts
]


def find_size_for_digit_height(target):
    """Binary-search the ttf point size whose '0' renders target px tall."""
    lo, hi = 8, 200
    while lo < hi:
        mid = (lo + hi) // 2
        font = ImageFont.truetype(TTF, mid)
        bbox = font.getbbox("0")
        h = bbox[3] - bbox[1]
        if h < target:
            lo = mid + 1
        else:
            hi = mid
    return lo


def build_font(name, digit_h, adv_trim, outdir):
    size = find_size_for_digit_height(digit_h)
    font = ImageFont.truetype(TTF, size)

    # Measure all glyphs relative to a common baseline.
    ascent, descent = font.getmetrics()
    glyphs = {}
    for ch in CHARS:
        bbox = font.getbbox(ch)  # (x0, y0, x1, y1) relative to text origin
        adv = int(round(font.getlength(ch)))
        glyphs[ch] = (bbox, max(1, adv - adv_trim))

    top = min(b[0][1] for b in glyphs.values())
    bottom = max(b[0][3] for b in glyphs.values())
    cell_h = bottom - top
    base = ascent - top          # baseline position within the trimmed cell
    line_h = cell_h + 2 * PAD

    atlas_w = sum(b[0][2] - b[0][0] + 2 * PAD for b in glyphs.values())
    atlas = Image.new("RGBA", (atlas_w, cell_h + 2 * PAD), (0, 0, 0, 0))
    draw = ImageDraw.Draw(atlas)

    entries = []
    x = 0
    for ch in CHARS:
        (x0, y0, x1, y1), adv = glyphs[ch]
        gw = x1 - x0
        gh = y1 - y0
        # Draw so the glyph's ink lands at (x+PAD, PAD + (y0 - top)).
        draw.text((x + PAD - x0, PAD - top), ch, font=font,
                  fill=(255, 255, 255, 255))
        entries.append({
            "id": ord(ch), "x": x + PAD - 1, "y": max(0, PAD + (y0 - top) - 1),
            "width": gw + 2, "height": gh + 2,
            "xoffset": x0 - 1, "yoffset": (y0 - top) + PAD - 1,
            "xadvance": adv,
        })
        x += gw + 2 * PAD

    # Threshold to 1-bit alpha: the Edge display renders semi-transparent
    # edge pixels near-solid, fattening antialiased glyphs by ~1px per edge.
    # Native bitmap fonts are crisp-edged; match that.
    px = atlas.load()
    for yy in range(atlas.height):
        for xx in range(atlas.width):
            r, gc, b, a = px[xx, yy]
            px[xx, yy] = (255, 255, 255, 255 if a >= 128 else 0)

    png = f"{name}.png"
    atlas.save(f"{outdir}/{png}")

    with open(f"{outdir}/{name}.fnt", "w") as f:
        # Declare zero padding: Connect IQ adds declared padding to every
        # glyph advance at measure time (+2px/char), even though the padding
        # is already baked into the glyph rects.
        f.write(f'info face="GarminRobotoBold" size={size} bold=1 italic=0 '
                f'charset="" unicode=1 stretchH=100 smooth=1 aa=1 '
                f'padding=0,0,0,0 spacing=0,0 outline=0\n')
        f.write(f'common lineHeight={line_h} base={base + PAD} '
                f'scaleW={atlas.width} scaleH={atlas.height} pages=1 '
                f'packed=0 alphaChnl=1 redChnl=0 greenChnl=0 blueChnl=0\n')
        f.write(f'page id=0 file="{png}"\n')
        f.write(f'chars count={len(entries)}\n')
        for e in entries:
            f.write(f'char id={e["id"]} x={e["x"]} y={e["y"]} '
                    f'width={e["width"]} height={e["height"]} '
                    f'xoffset={e["xoffset"]} yoffset={e["yoffset"]} '
                    f'xadvance={e["xadvance"]} page=0 chnl=15\n')

    print(f"{outdir}/{name}: ttf size {size}, digit_h {digit_h}, "
          f"lineHeight {line_h}, base {base + PAD}, atlas {atlas.size}")


def main():
    outdirs = sys.argv[1:]
    if not outdirs:
        print(__doc__)
        sys.exit(1)
    for outdir in outdirs:
        for name, digit_h, adv_trim in FONTS:
            build_font(name, digit_h, adv_trim, outdir)


if __name__ == "__main__":
    main()
