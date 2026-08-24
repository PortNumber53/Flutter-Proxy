#!/usr/bin/env python3
"""
Install a 1024x1024 master logo into the Android and iOS icon sets.

    /Users/grimlock/ComfyUI/venv/bin/python tool/install_icons.py assets/generated/<name>.png [bg-key-tolerance]

The optional tolerance (default 42) controls how aggressively the flat background
is keyed out before the mark is cropped to fill the adaptive-icon safe zone.
Raise it when the art has a soft//vignetted field so the mark is not left floating;
lower it if keying starts eating into the mark itself.

(Uses Pillow; the ComfyUI venv already has it.)
"""
import json, os, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ANDROID = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# Adaptive icons are 108dp but only the middle ~72dp is guaranteed visible, so the
# foreground layer is the artwork scaled down and padded. Without this the
# launcher's circular/squircle mask crops straight into the mark.
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
SAFE_FRACTION = 0.62


def load_master(path):
    im = Image.open(path).convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    return im


def _pixels(px):
    """Iterate RGBA tuples without Image.getdata(), deprecated in Pillow 12."""
    raw = px.tobytes()
    for i in range(0, len(raw), 4):
        yield raw[i], raw[i + 1], raw[i + 2], raw[i + 3]


def extract_mark(im, tol=42):
    """Key out the flat background and crop to the mark itself.

    The generated art is a full-bleed square: mark plus a solid field. Pasting
    that whole square into the adaptive foreground leaves the mark small and
    puts a faint square seam over the background layer. Removing the field and
    cropping to the artwork lets the mark actually fill the safe zone.
    """
    bg = bg_color(im)[:3]
    px = im.convert("RGBA")
    out = []
    for r, g, b, a in _pixels(px):
        if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) <= tol:
            out.append((r, g, b, 0))
        else:
            out.append((r, g, b, a))
    px.frombytes(bytes(b for p in out for b in p))
    box = px.getbbox()
    if box is None:
        return im.convert("RGBA")          # all background; keep as-is
    cropped = px.crop(box)
    # Square it off so the aspect ratio survives the later resize.
    side = max(cropped.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(cropped, ((side - cropped.width) // 2, (side - cropped.height) // 2))
    return square


def bg_color(im):
    """Sample the corners -- the generated art has a solid field we can extend."""
    px = im.convert("RGB").load()
    w, h = im.size
    pts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
    return (sum(px[x, y][0] for x, y in pts) // 4,
            sum(px[x, y][1] for x, y in pts) // 4,
            sum(px[x, y][2] for x, y in pts) // 4, 255)


KEY_TOL = 42


def write_android(im):
    res = os.path.join(ROOT, "android/app/src/main/res")
    for d, px in ANDROID.items():
        out = os.path.join(res, "mipmap-" + d)
        os.makedirs(out, exist_ok=True)
        im.resize((px, px), Image.LANCZOS).save(os.path.join(out, "ic_launcher.png"))

    col = bg_color(im)
    mark = extract_mark(im, KEY_TOL)
    for d, px in ADAPTIVE.items():
        out = os.path.join(res, "mipmap-" + d)
        os.makedirs(out, exist_ok=True)
        inner = int(px * SAFE_FRACTION)
        fg = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        art = mark.resize((inner, inner), Image.LANCZOS)
        fg.paste(art, ((px - inner) // 2, (px - inner) // 2), art)
        fg.save(os.path.join(out, "ic_launcher_foreground.png"))

    vals = os.path.join(res, "values")
    os.makedirs(vals, exist_ok=True)
    hexcol = "#%02X%02X%02X" % col[:3]
    open(os.path.join(vals, "ic_launcher_background.xml"), "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">' + hexcol + '</color>\n</resources>\n')

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@color/ic_launcher_background"/>\n'
           '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
           '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
           '</adaptive-icon>\n')
    for n in ("ic_launcher.xml", "ic_launcher_round.xml"):
        open(os.path.join(anydpi, n), "w").write(xml)
    print("   android: 5 legacy + 5 adaptive foregrounds, background " + hexcol)


def write_ios(im):
    d = os.path.join(ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
    spec = json.load(open(os.path.join(d, "Contents.json")))
    # iOS icons must be opaque; an alpha channel is rejected at submission.
    flat = Image.new("RGB", im.size, bg_color(im)[:3])
    flat.paste(im, (0, 0), im)
    done = set()
    for entry in spec["images"]:
        fn = entry["filename"]
        if fn in done:
            continue
        done.add(fn)
        base = float(entry["size"].split("x")[0])
        px = int(round(base * int(entry["scale"].rstrip("x"))))
        flat.resize((px, px), Image.LANCZOS).save(os.path.join(d, fn))
    print("   ios: %d icons (opaque)" % len(done))


def write_app_asset(im):
    out = os.path.join(ROOT, "assets/logo")
    os.makedirs(out, exist_ok=True)
    for px in (512, 256, 128):
        im.resize((px, px), Image.LANCZOS).save(os.path.join(out, "logo_%d.png" % px))
    print("   assets/logo/logo_{512,256,128}.png")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    if len(sys.argv) == 3:
        KEY_TOL = int(sys.argv[2])
        globals()["KEY_TOL"] = KEY_TOL
    master = load_master(sys.argv[1])
    print("installing " + sys.argv[1])
    write_android(master)
    write_ios(master)
    write_app_asset(master)
    print("done")
