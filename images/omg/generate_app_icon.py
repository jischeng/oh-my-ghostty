#!/usr/bin/env python3
"""Generate the OMG macOS icon set from the maintained 1024px source.

The base keeps Ghostty's recognizable terminal/ghost visual language. OMG adds
a simple opaque foreground cloud so titlebar, Dock, Finder, and
transparent/vibrant backgrounds render the same branded mark.
"""

from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name("ghostty-base-1024.png")
MASTER = Path(__file__).with_name("omg-app-icon-1024.png")
APPICONSET = ROOT / "macos/Assets.xcassets/OMG.appiconset"
RUNTIME_IMAGESET = ROOT / "macos/Assets.xcassets/AppIconImage.imageset"


def cloud_mask(size: tuple[int, int]) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    # The cloud sits in front of the ghost's lower half, matching the
    # supplied brand sketch so the two shapes read as one mark rather than
    # separate stickers.
    draw.rounded_rectangle((220, 455, 560, 600), radius=72, fill=255)
    draw.ellipse((200, 425, 320, 545), fill=255)
    draw.ellipse((260, 385, 395, 535), fill=255)
    draw.ellipse((350, 405, 485, 545), fill=255)
    draw.ellipse((440, 435, 580, 565), fill=255)
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
    highlight_draw.arc((255, 395, 475, 550), 205, 325, fill=(255, 255, 255, 175), width=7)
    highlight.putalpha(Image.composite(highlight.getchannel("A"), Image.new("L", base.size), mask))
    return Image.alpha_composite(base, highlight)


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
