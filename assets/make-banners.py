#!/usr/bin/env python3
"""Generate the README pixel-art banners (original artwork, not Mojang assets).

    python3 assets/make-banners.py
"""
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))

# 5x7 pixel font, just the glyphs we need.
FONT = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "·": ["00000", "00000", "00000", "01100", "01100", "00000", "00000"],
    " ": ["00000"] * 7,
}


def text_width(s, px):
    return len(s) * 6 * px - px


def pixel_text(s, x, y, px, fill, shadow=None):
    out = []
    for layer, (dx, color) in enumerate(([(px, shadow)] if shadow else []) + [(0, fill)]):
        cx = x
        for ch in s:
            for r, row in enumerate(FONT[ch]):
                for c, bit in enumerate(row):
                    if bit == "1":
                        out.append(f'<rect x="{cx + c * px + dx}" y="{y + r * px + dx}" '
                                   f'width="{px}" height="{px}" fill="{color}"/>')
            cx += 6 * px
    return "\n".join(out)


GRASS = ["#5d9e34", "#6bb23c", "#4f8a2b", "#78c046", "#5a9a31"]
DIRT = ["#866043", "#79553a", "#96704f", "#6b4a31", "#8b6446"]
STONE = ["#7d7d7d", "#8a8a8a", "#6f6f6f", "#949494"]


def ground_strip(width, y, px, rng, grass_rows=2, dirt_rows=5, stone_rows=0):
    out = []
    cols = width // px
    for c in range(cols):
        # grass hangs down a little unevenly, like the block side texture
        drip = rng.choice([0, 0, 1, 1, 2])
        for r in range(grass_rows + dirt_rows + stone_rows):
            if r < grass_rows + drip:
                color = rng.choice(GRASS)
            elif r < grass_rows + dirt_rows:
                color = rng.choice(DIRT)
            else:
                color = rng.choice(STONE)
            out.append(f'<rect x="{c * px}" y="{y + r * px}" width="{px}" height="{px}" fill="{color}"/>')
    return "\n".join(out)


def iso_block(cx, top, size, px, rng):
    """Isometric grass block drawn as pixel columns. (cx, top) = top corner."""
    out = []
    n = size // px                 # pixels along one edge
    h = n                          # side height in pixels
    for i in range(n):             # top face: diamond made of 2:1 pixels
        for j in range(n):
            x = cx + (i - j) * px
            y = top + (i + j) * px // 2
            out.append(f'<polygon points="{x},{y} {x + px},{y + px / 2} {x},{y + px} {x - px},{y + px / 2}" '
                       f'fill="{rng.choice(GRASS)}"/>')
    for side, shade in ((-1, 0.78), (1, 0.6)):   # left and right faces
        for i in range(n):
            drip = rng.choice([2, 3, 3, 4])
            for k in range(h):
                if k < drip:
                    base = rng.choice(GRASS)
                else:
                    base = rng.choice(DIRT)
                r, g, b = (int(base[p:p + 2], 16) for p in (1, 3, 5))
                col = f"#{int(r * shade):02x}{int(g * shade):02x}{int(b * shade):02x}"
                if side < 0:
                    x0 = cx - n * px + i * px
                    y0 = top + n * px / 2 + i * px / 2 + k * px
                else:
                    x0 = cx + i * px
                    y0 = top + n * px + k * px - (i + 1) * px / 2
                x1 = x0 + px
                if side < 0:
                    pts = f"{x0},{y0} {x1},{y0 + px / 2} {x1},{y0 + px * 1.5} {x0},{y0 + px}"
                else:
                    pts = f"{x0},{y0 + px / 2} {x1},{y0} {x1},{y0 + px} {x0},{y0 + px * 1.5}"
                out.append(f'<polygon points="{pts}" fill="{col}"/>')
    return "\n".join(out)


def header():
    W, H, px = 1280, 360, 8
    rng = random.Random(173)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
             f'shape-rendering="crispEdges" role="img" aria-label="Beta 1.7.3 Server">',
             ]
    # sky in flat bands (pixel-art style, no gradients to render differently)
    bands = ["#5f8ad8", "#6894de", "#739ee3", "#7fa8e8", "#8bb2ec", "#98bcf0", "#a6c6f3"]
    bh = H // len(bands) + 1
    for i, c in enumerate(bands):
        parts.append(f'<rect x="0" y="{i * bh}" width="{W}" height="{bh}" fill="{c}"/>')
    # blocky clouds
    for cx, cy, w in ((40, 22, 18), (540, 18, 14), (930, 22, 16), (1170, 150, 11)):
        for r in range(2):
            parts.append(f'<rect x="{cx + r * px * 2}" y="{cy + r * px}" width="{(w - r * 4) * px}" '
                         f'height="{px * 2}" fill="#ffffff" opacity="0.85"/>')
    # sun
    parts.append(f'<rect x="1196" y="40" width="{px * 7}" height="{px * 7}" fill="#fff6a8"/>')
    parts.append(f'<rect x="1204" y="48" width="{px * 5}" height="{px * 5}" fill="#fffbe0"/>')
    parts.append(ground_strip(W, H - px * 9, px, rng, grass_rows=2, dirt_rows=5, stone_rows=2))
    parts.append(iso_block(185, 88, 96, px, rng))
    title, sub = "BETA 1.7.3", "SERVER INSTALLER"
    tpx, spx = 13, 6
    tx = 360
    parts.append(pixel_text(title, tx, 70, tpx, "#ffffff", shadow="#3f3f3f"))
    parts.append(pixel_text(sub, tx + 4, 70 + 7 * tpx + 24, spx, "#fcee4b", shadow="#3f3f15"))
    parts.append("</svg>")
    return "\n".join(parts)


def divider():
    W, px = 1280, 8
    rng = random.Random(1703)
    H = px * 5
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'shape-rendering="crispEdges" role="img" aria-label="">',
        ground_strip(W, 0, px, rng, grass_rows=2, dirt_rows=3),
        "</svg>",
    ])


def footer():
    W, H, px = 1280, 120, 8
    rng = random.Random(1873)
    text = "NO HUNGER BAR · JUST BLOCKS"
    tp = 5
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
             f'shape-rendering="crispEdges" role="img" aria-label="No hunger bar, just blocks">']
    parts.append(ground_strip(W, 0, px, rng, grass_rows=0, dirt_rows=5, stone_rows=10))
    x = (W - text_width(text, tp)) // 2
    parts.append(pixel_text(text, x, (H - 7 * tp) // 2, tp, "#ffffff", shadow="#2a2a2a"))
    parts.append("</svg>")
    return "\n".join(parts)


for name, svg in (("banner.svg", header()), ("divider.svg", divider()), ("footer.svg", footer())):
    with open(os.path.join(HERE, name), "w") as f:
        f.write(svg + "\n")
    print("wrote", name)
