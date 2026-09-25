#!/usr/bin/env python3
"""Compose an Android launcher icon from a logo plus a caption band.

Why: the hub and waiter apps share the same logo, so the waiter build gets a
"STAFF" band across the bottom to tell them apart on the home screen.

Usage (from the Flutter app directory):
  python3 tools/app_icon.py --logo ../../logo.png --text STAFF \
      --out android/app/src/main/res

Writes ic_launcher.png at every launcher density.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Android launcher icon sizes per density.
DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

MASTER = 1024
BRAND_GREEN = (27, 94, 32)  # #1B5E20
WHITE = (255, 255, 255)
DEFAULT_FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FALLBACK_FONTS = [
    "/System/Library/Fonts/Supplemental/Verdana Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def cover(image: Image.Image, size: int) -> Image.Image:
    """Scale and centre-crop so the image fills a size x size square."""
    scale = max(size / image.width, size / image.height)
    resized = image.resize(
        (round(image.width * scale), round(image.height * scale)), Image.LANCZOS
    )
    left = (resized.width - size) // 2
    top = (resized.height - size) // 2
    return resized.crop((left, top, left + size, top + size))


def load_font(preferred: str, size: int) -> ImageFont.FreeTypeFont:
    for path in [preferred, *FALLBACK_FONTS]:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default(size)


def draw_caption(
    canvas: Image.Image,
    text: str,
    band_ratio: float,
    colour: tuple,
    font_path: str,
) -> None:
    """Draw a solid band along the bottom with the text centred in it."""
    band = max(1, int(canvas.height * band_ratio))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle(
        [0, canvas.height - band, canvas.width, canvas.height], fill=colour
    )

    font_size = max(8, int(band * 0.5))
    font = load_font(font_path, font_size)
    tracking = max(0, int(font_size * 0.14))

    widths = [draw.textlength(char, font=font) for char in text]
    total = sum(widths) + tracking * max(0, len(text) - 1)

    x = (canvas.width - total) / 2
    ascent, descent = font.getmetrics()
    y = canvas.height - band + (band - (ascent + descent)) / 2 + ascent

    for char, width in zip(text, widths):
        # anchor="ls" puts the baseline at y, so the text sits centred.
        draw.text((x, y), char, font=font, fill=WHITE, anchor="ls")
        x += width + tracking


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logo", required=True, help="source logo image")
    parser.add_argument("--out", required=True, help="android res directory")
    parser.add_argument("--text", default="STAFF", help="caption text")
    parser.add_argument(
        "--band",
        type=float,
        default=0.22,
        help="band height as a fraction of the icon (default 0.22)",
    )
    parser.add_argument("--font", default=DEFAULT_FONT, help="bold font file")
    args = parser.parse_args()

    logo = Image.open(args.logo).convert("RGB")
    master = cover(logo, MASTER)
    if args.text:
        draw_caption(master, args.text, args.band, BRAND_GREEN, args.font)

    out = Path(args.out)
    for density, size in DENSITIES.items():
        target = out / f"mipmap-{density}"
        target.mkdir(parents=True, exist_ok=True)
        path = target / "ic_launcher.png"
        master.resize((size, size), Image.LANCZOS).save(path)
        print(f"wrote {path} ({size}x{size})")


if __name__ == "__main__":
    main()
