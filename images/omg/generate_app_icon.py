#!/usr/bin/env python3
"""Generate the OMG macOS icon set from the maintained 1024px source.

The base keeps Ghostty's recognizable terminal/ghost visual language. OMG adds
an opaque cloud terminal badge on the right so titlebar, Dock, Finder, and
transparent/vibrant backgrounds render the same branded mark.
"""

from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name("ghostty-base-1024.png")
MASTER = Path(__file__).with_name("omg-app-icon-1024.png")
APPICONSET = ROOT / "macos/Assets.xcassets/OMG.appiconset"
RUNTIME_IMAGESET = ROOT / "macos/Assets.xcassets/AppIconImage.imageset"
FONT = Path("/System/Library/Fonts/SFNSMono.ttf")


def cloud_mask(size: tuple[int, int]) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    # The cloud sits in front of the ghost's lower-right edge, matching the
    # supplied brand sketch so the two shapes read as one mark rather than
    # separate stickers.
    draw.rounded_rectangle((390, 455, 730, 600), radius=72, fill=255)
    draw.ellipse((370, 425, 490, 545), fill=255)
    draw.ellipse((430, 385, 565, 535), fill=255)
    draw.ellipse((520, 405, 655, 545), fill=255)
    draw.ellipse((610, 435, 750, 565), fill=255)
    return mask


def vertical_gradient(size: tuple[int, int], top: tuple[int, ...], bottom: tuple[int, ...]) -> Image.Image:
    image = Image.new("RGBA", size)
    pixels = image.load()
    for y in range(size[1]):
        t = y / max(size[1] - 1, 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(size[0]):
            pixels[x, y] = color
    return image


def draw_centered(draw: ImageDraw.ImageDraw, text: str, center: tuple[int, int], font: ImageFont.FreeTypeFont) -> None:
    bounds = draw.textbbox((0, 0), text, font=font)
    width = bounds[2] - bounds[0]
    height = bounds[3] - bounds[1]
    origin = (center[0] - width / 2, center[1] - height / 2 - bounds[1])
    draw.text((origin[0] + 2, origin[1] + 3), text, font=font, fill=(112, 184, 255, 120))
    draw.text(origin, text, font=font, fill=(8, 35, 91, 255))


def generate_master() -> Image.Image:
    base = Image.open(SOURCE).convert("RGBA")
    if base.size != (1024, 1024):
        raise ValueError(f"expected a 1024px source, got {base.size}")

    mask = cloud_mask(base.size)

    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    shadow_alpha = mask.filter(ImageFilter.GaussianBlur(24))
    shadow_alpha = shadow_alpha.transform(base.size, Image.Transform.AFFINE, (1, 0, -10, 0, 1, -18))
    shadow.putalpha(shadow_alpha.point(lambda value: round(value * 0.5)))
    shadow.paste((4, 12, 42, 255), (0, 0), shadow)
    base = Image.alpha_composite(base, shadow)

    glow = Image.new("RGBA", base.size, (92, 190, 255, 0))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(18)).point(lambda value: round(value * 0.42)))
    base = Image.alpha_composite(base, glow)

    fill = vertical_gradient(base.size, (239, 250, 255, 255), (140, 195, 255, 255))
    cloud = Image.new("RGBA", base.size, (0, 0, 0, 0))
    cloud.paste(fill, (0, 0), mask)

    outline_mask = ImageChops.subtract(
        mask.filter(ImageFilter.MaxFilter(11)),
        mask,
    )
    outline = Image.new("RGBA", base.size, (101, 183, 255, 0))
    outline.putalpha(outline_mask)
    base = Image.alpha_composite(base, outline)
    base = Image.alpha_composite(base, cloud)

    highlight = Image.new("RGBA", base.size, (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.arc((425, 395, 645, 550), 205, 325, fill=(255, 255, 255, 175), width=7)
    highlight.putalpha(Image.composite(highlight.getchannel("A"), Image.new("L", base.size), mask))
    base = Image.alpha_composite(base, highlight)

    symbols = Image.new("RGBA", base.size, (0, 0, 0, 0))
    symbol_draw = ImageDraw.Draw(symbols)
    font = ImageFont.truetype(str(FONT), 36)
    draw_centered(symbol_draw, "~  @", (610, 475), font)
    draw_centered(symbol_draw, "$  *", (610, 525), font)
    symbols.putalpha(Image.composite(symbols.getchannel("A"), Image.new("L", base.size), mask))
    return Image.alpha_composite(base, symbols)


def save_outputs(master: Image.Image) -> None:
    MASTER.parent.mkdir(parents=True, exist_ok=True)
    APPICONSET.mkdir(parents=True, exist_ok=True)
    master.save(MASTER, optimize=True)

    outputs = {
        "omg-icon-16.png": 16,
        "omg-icon-16@2x.png": 32,
        "omg-icon-32.png": 32,
        "omg-icon-32@2x.png": 64,
        "omg-icon-128.png": 128,
        "omg-icon-128@2x.png": 256,
        "omg-icon-256.png": 256,
        "omg-icon-256@2x.png": 512,
        "omg-icon-512.png": 512,
        "omg-icon-512@2x.png": 1024,
    }
    for name, size in outputs.items():
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(APPICONSET / name, optimize=True)

    for name, size in {
        "macOS-AppIcon-256px-128pt@2x.png": 256,
        "macOS-AppIcon-512px.png": 512,
        "macOS-AppIcon-1024px.png": 1024,
    }.items():
        master.resize((size, size), Image.Resampling.LANCZOS).save(
            RUNTIME_IMAGESET / name,
            optimize=True,
        )


if __name__ == "__main__":
    save_outputs(generate_master())
