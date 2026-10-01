#!/usr/bin/env python3
"""Compose the iOS app icon from the harness's own brand mark.

The upstream favicon is a transparent black glyph, which is not usable as an app
icon on its own: iOS icons must be opaque, and a bare glyph is illegible against
dark wallpapers. This places the official mark on a solid field with the padding
Apple's icon grid expects, so the icon is derived from upstream branding rather
than invented.
"""
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: python3 -m pip install Pillow")

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "Apps/DeepSeekHarnessStandalone/Resources/HarnessAssets/favicon.svg"
ICONSET = ROOT / "Apps/DeepSeekHarnessStandalone/Resources/Assets.xcassets/AppIcon.appiconset"

SIZE = 1024
# iOS icons are full-bleed; the system applies the squircle mask, so the mark
# itself must stay inside roughly the middle 70% to avoid being clipped.
GLYPH_FRACTION = 0.62


def render_glyph(px: int, out: Path) -> Path:
    """Rasterize the brand SVG at the requested pixel size."""
    subprocess.run(
        ["rsvg-convert", "-w", str(px), "-h", str(px), str(SVG), "-o", str(out)],
        check=True,
    )
    return out


def main() -> int:
    if not SVG.exists():
        sys.exit(f"brand mark not found: {SVG}")

    ICONSET.mkdir(parents=True, exist_ok=True)

    glyph_px = int(SIZE * GLYPH_FRACTION)
    tmp_glyph = Path("/tmp/dsh-icon-glyph.png")
    render_glyph(glyph_px, tmp_glyph)

    glyph = Image.open(tmp_glyph).convert("RGBA")

    # A near-white field keeps the black mark legible in dark mode and matches
    # the product's light UI, which is what the shipped client defaults to.
    canvas = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))

    offset = ((SIZE - glyph_px) // 2, (SIZE - glyph_px) // 2)
    canvas.paste(glyph, offset, glyph)

    # iOS rejects icons with an alpha channel, so flatten explicitly.
    flattened = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
    flattened.paste(canvas, (0, 0), canvas)

    icon_path = ICONSET / "AppIcon-1024.png"
    flattened.save(icon_path, "PNG")

    # A single 1024 icon is all modern Xcode needs; it derives the rest.
    contents = """{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
    (ICONSET / "Contents.json").write_text(contents, encoding="utf-8")
    (ICONSET.parent / "Contents.json").write_text(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n',
        encoding="utf-8",
    )

    print(f"wrote {icon_path} ({icon_path.stat().st_size} bytes)")
    print(f"  glyph {glyph_px}px centred in {SIZE}x{SIZE}, opaque, no alpha")
    tmp_glyph.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
