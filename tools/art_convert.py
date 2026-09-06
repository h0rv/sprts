"""Logo -> mark conversion. Source-agnostic; works on a grayscale image.

Marks are Unicode braille (U+2800-U+28FF, 2x4 dots per cell, one terminal
cell each) so a 18x4-cell mark carries a 36x16-pixel logo in 4 rows.
Everything is single-cell, so terminal width math stays trivial.
"""

from __future__ import annotations

import io
import urllib.request
from pathlib import Path

# (size, cell columns). sm is the board mark: 22 cells carries internal
# detail (animal faces, interlocks) that 18 cells turns to mush.
SIZES = (("xs", 14), ("sm", 22), ("md", 28))
MAX_COLS = 46  # cells; 80-col terminals never wrap
BLANK = "\u2800"


def load_gray(path: str | None, url: str | None):
    from PIL import Image, ImageChops

    if path is not None:
        im = Image.open(path).convert("RGBA")
    else:
        assert url is not None
        with urllib.request.urlopen(url, timeout=30) as resp:
            im = Image.open(io.BytesIO(resp.read())).convert("RGBA")
    white = Image.new("RGBA", im.size, (255, 255, 255, 255))
    gray = Image.alpha_composite(white, im).convert("L")
    bbox = ImageChops.invert(gray).getbbox()
    if bbox:
        gray = gray.crop(bbox)
    return gray


def otsu_threshold(small) -> int:
    hist = small.histogram()
    total = sum(hist)
    best, best_t, sum_all = 0.0, 128, sum(i * h for i, h in enumerate(hist))
    sum_bg, weight_bg = 0, 0
    for t in range(256):
        weight_bg += hist[t]
        if weight_bg == 0:
            continue
        weight_fg = total - weight_bg
        if weight_fg == 0:
            break
        sum_bg += t * hist[t]
        mean_bg = sum_bg / weight_bg
        mean_fg = (sum_all - sum_bg) / weight_fg
        between = weight_bg * weight_fg * (mean_bg - mean_fg) ** 2
        if between > best:
            best, best_t = between, t
    return best_t


def to_braille(gray, cols: int) -> list[str]:
    """Render cols-wide braille cells; height follows the logo aspect."""
    from PIL import Image, ImageOps

    # Dark-on-transparent marks composited onto white would vanish; flip them.
    probe = gray.resize((8, 8), Image.BILINEAR)
    if sum(probe.tobytes()) / 64 < 128:
        gray = ImageOps.invert(gray)
    w, h = gray.size
    # 2x4 pixels per cell; cells are ~2x tall, hence the 0.5.
    px_w, px_h = cols * 2, max(4, int(h / w * cols * 2 * 0.5))
    px_h = (px_h + 3) // 4 * 4  # whole cells
    small = gray.resize((px_w, px_h), Image.LANCZOS)
    threshold = otsu_threshold(small)
    px = list(small.tobytes())
    dots = [1 if v < threshold else 0 for v in px]
    rows: list[str] = []
    for by in range(0, px_h, 4):
        row = ""
        for bx in range(0, px_w, 2):
            bits = 0
            for dx, dy, mask in (
                (0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04),
                (1, 0, 0x08), (1, 1, 0x10), (1, 2, 0x20),
                (0, 3, 0x40), (1, 3, 0x80),
            ):
                if dots[(by + dy) * px_w + bx + dx]:
                    bits |= mask
            row += chr(0x2800 + bits)
        rows.append(row.rstrip(BLANK))
    while rows and not rows[0].strip(BLANK):
        rows.pop(0)
    while rows and not rows[-1].strip(BLANK):
        rows.pop()
    for row in rows:
        cells = len(row)
        if cells > MAX_COLS:
            raise SystemExit(f"row wider than {MAX_COLS} cells")
        for ch in row:
            if not 0x2800 <= ord(ch) <= 0x28FF:
                raise SystemExit(f"non-braille char in art: {ch!r}")
    return rows


def check_file(path: Path) -> None:
    """Validate a checked-in mark (used by --check and Zig tests mirror it)."""
    text = path.read_text(encoding="utf-8")
    assert text.endswith("\n"), f"{path}: missing trailing newline"
    for line in text.split("\n"):
        if not line:
            continue
        assert len(line) <= MAX_COLS, f"{path}: line wider than {MAX_COLS} cells"
        for ch in line:
            assert 0x2800 <= ord(ch) <= 0x28FF, f"{path}: non-braille char {ch!r}"
