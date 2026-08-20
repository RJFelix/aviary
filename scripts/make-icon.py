#!/usr/bin/env python3
"""Generate Aviary.icns without any image dependencies.

The app icon is a teal rounded square with a stylised bird. Drawing it here — as raw RGBA
pixels composited into PNGs and packed into an .icns — avoids checking a binary asset into
the repo, and keeps the icon editable as code. No Pillow, no ImageMagick, no Xcode asset
catalog: just zlib and struct, both in the standard library.
"""

from __future__ import annotations

import math
import struct
import sys
import zlib

# Aviary's accent teal, and a lighter tint for the gradient.
TEAL_DARK = (16, 122, 120)
TEAL_LIGHT = (44, 184, 178)
GLYPH = (255, 255, 255)


def rounded_rect_alpha(x: float, y: float, size: int, radius: float) -> float:
    """Coverage of a rounded square at a point, with a soft one-pixel edge.

    The standard rounded-box signed distance field. Writing it as three separate cases
    (inside / corner / edge) looks equivalent and is not: it produces a visible seam where
    the cases meet, which shows up as a faint square outline inside the tile.
    """
    half = size / 2.0
    dx = abs(x - half) - (half - radius)
    dy = abs(y - half) - (half - radius)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    d = outside + inside - radius
    return max(0.0, min(1.0, 0.5 - d))


# A bird in flight, side profile, as one closed polygon in a 0..1 box (y grows downward).
# A polygon rather than a union of ellipses: overlapping ellipses reliably read as an
# insect, and the shape that reads as a *bird* at 16 pixels needs a tail fork and a beak,
# neither of which an ellipse union gives you.
BIRD = [
    (0.180, 0.615),  # tail, upper fork
    (0.300, 0.575),
    (0.415, 0.545),
    (0.470, 0.500),  # wing root
    (0.430, 0.380),
    (0.400, 0.268),  # wing tip
    (0.470, 0.300),
    (0.520, 0.375),
    (0.560, 0.450),  # wing trailing edge back at the body
    (0.640, 0.428),
    (0.700, 0.408),  # head
    (0.745, 0.422),
    (0.840, 0.452),  # beak
    (0.742, 0.470),
    (0.678, 0.482),
    (0.590, 0.520),
    (0.470, 0.582),
    (0.340, 0.645),
    (0.232, 0.678),  # tail, lower fork
    (0.268, 0.628),  # notch between the fork tips
]


def _inside(u: float, v: float) -> bool:
    """Even-odd point-in-polygon."""
    inside = False
    n = len(BIRD)
    for i in range(n):
        x0, y0 = BIRD[i]
        x1, y1 = BIRD[(i + 1) % n]
        if (y0 > v) != (y1 > v):
            xint = x0 + (v - y0) * (x1 - x0) / (y1 - y0)
            if u < xint:
                inside = not inside
    return inside


def bird_alpha(px: float, py: float, size: int) -> float:
    """Coverage of the bird at a pixel, supersampled 3x3 for a clean edge."""
    hits = 0
    for sy in (0.1667, 0.5, 0.8333):
        for sx in (0.1667, 0.5, 0.8333):
            if _inside((px - 0.5 + sx) / size, (py - 0.5 + sy) / size):
                hits += 1
    return hits / 9.0


def render(size: int) -> bytes:
    """Return raw RGBA rows for one square icon size."""
    radius = size * 0.223  # macOS "squircle" proportion, near enough by eye
    rows = bytearray()
    for py in range(size):
        rows.append(0)  # PNG filter type 0
        for px in range(size):
            cover = rounded_rect_alpha(px + 0.5, py + 0.5, size, radius)
            if cover <= 0.0:
                rows.extend((0, 0, 0, 0))
                continue
            # Vertical gradient across the tile.
            t = py / max(1, size - 1)
            r = round(TEAL_LIGHT[0] + (TEAL_DARK[0] - TEAL_LIGHT[0]) * t)
            g = round(TEAL_LIGHT[1] + (TEAL_DARK[1] - TEAL_LIGHT[1]) * t)
            b = round(TEAL_LIGHT[2] + (TEAL_DARK[2] - TEAL_LIGHT[2]) * t)

            glyph = bird_alpha(px + 0.5, py + 0.5, size)
            if glyph > 0.0:
                r = round(r + (GLYPH[0] - r) * glyph)
                g = round(g + (GLYPH[1] - g) * glyph)
                b = round(b + (GLYPH[2] - b) * glyph)

            rows.extend((r, g, b, round(255 * cover)))
    return bytes(rows)


def png(size: int) -> bytes:
    raw = render(size)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


# icns type codes for the sizes Finder and the Dock actually ask for.
ENTRIES = [
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic13", 256),
    (b"ic14", 512),
]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: make-icon.py <out.icns>", file=sys.stderr)
        return 2
    out_path = sys.argv[1]

    cache: dict[int, bytes] = {}
    body = bytearray()
    for tag, size in ENTRIES:
        if size not in cache:
            cache[size] = png(size)
        data = cache[size]
        # An icns element is: 4-byte type, 4-byte length *including these 8 bytes*, payload.
        body += tag + struct.pack(">I", len(data) + 8) + data

    payload = bytes(body)
    with open(out_path, "wb") as fh:
        fh.write(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
