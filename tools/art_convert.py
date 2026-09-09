"""Logo -> mark conversion. Source-agnostic; works on a grayscale image.

Marks are Unicode braille (U+2800-U+28FF, 2x4 dots per cell, one terminal
cell each) so a 18x4-cell mark carries a 36x16-pixel logo in 4 rows.
Everything is single-cell, so terminal width math stays trivial.
"""

from __future__ import annotations

import io
import re
import urllib.request
from pathlib import Path

# (size, cell columns). sm is the board mark: 22 cells carries internal
# detail (animal faces, interlocks) that 18 cells turns to mush.
SIZES = (("xs", 14), ("sm", 22), ("md", 28))
MAX_COLS = 46  # cells; 80-col terminals never wrap
BLANK = "\u2800"


def load_gray(path: str | None, url: str | None):
    gray, _ = load_both(path, url)
    return gray


def load_both(path: str | None, url: str | None):
    """Load a logo as (gray, rgba), normalized to a centered square.

    load_gray() stays the mono entry point so existing callers are
    untouched; color conversion needs the RGBA twin cropped identically.

    Normalization (so every mark renders at a consistent size/position):
    crop to the ink bounding box, paste centered on a square canvas
    (side = max dimension), and return the square pair. Downstream
    `grid_size` then sees identical aspect for every logo, so row counts
    stop varying with the source image's original proportions.
    """
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
        im = im.crop(bbox)
    side = max(gray.size[0], gray.size[1])
    if side <= 0:
        return gray, im
    square_gray = Image.new("L", (side, side), 255)
    square_gray.paste(gray, ((side - gray.size[0]) // 2, (side - gray.size[1]) // 2))
    square_rgba = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square_rgba.alpha_composite(im, ((side - im.size[0]) // 2, (side - im.size[1]) // 2))
    return square_gray, square_rgba


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


def grid_size(gray, cols: int) -> tuple[int, int]:
    """Cell-grid pixel dims for cols-wide braille. Shared by mono/color."""
    w, h = gray.size
    # 2x4 pixels per cell; cells are ~2x tall, hence the 0.5.
    px_w, px_h = cols * 2, max(4, int(h / w * cols * 2 * 0.5))
    px_h = (px_h + 3) // 4 * 4  # whole cells
    return px_w, px_h


# xterm-256 palette (indices 16-255; 0-15 are terminal-themed, so the
# mapping targets the portable cube + grayscale ramp only).
_CUBE_LEVELS = (0, 95, 135, 175, 215, 255)
_XTERM_PALETTE: list[tuple[int, int, int]] = [(0, 0, 0)] * 16
for _r in _CUBE_LEVELS:
    for _g in _CUBE_LEVELS:
        for _b in _CUBE_LEVELS:
            _XTERM_PALETTE.append((_r, _g, _b))
for _i in range(24):
    _v = 8 + 10 * _i
    _XTERM_PALETTE.append((_v, _v, _v))
assert len(_XTERM_PALETTE) == 256


def rgb_to_xterm(r: int, g: int, b: int) -> int:
    """Nearest xterm-256 color (cube + grayscale ramp, indices 16-255)."""
    best, best_d = 16, None
    for i in range(16, 256):
        pr, pg, pb = _XTERM_PALETTE[i]
        d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if best_d is None or d < best_d:
            best, best_d = i, d
    return best


_SGR_RE = re.compile(r"\x1b\[[0-9;]+m")


def strip_sgr(text: str) -> str:
    """Remove SGR escape runs; the remainder must equal the mono mark."""
    return _SGR_RE.sub("", text)


def to_braille_color(gray, color_img, cols: int) -> list[str]:
    """Color twin of to_braille(): same geometry, SGR `38;5;N` runs.

    Per cell, average the RGB of inked (dark + opaque) pixels and quantize
    to xterm-256. Transparent/background cells stay uncolored. Stripping
    all `\\x1b[...m` runs must reproduce to_braille(gray, cols) exactly.
    """
    from PIL import Image, ImageOps

    probe = gray.resize((8, 8), Image.BILINEAR)
    if sum(probe.tobytes()) / 64 < 128:
        gray = ImageOps.invert(gray)
    px_w, px_h = grid_size(gray, cols)
    small = gray.resize((px_w, px_h), Image.LANCZOS)
    threshold = otsu_threshold(small)
    px = list(small.tobytes())
    dots = [1 if v < threshold else 0 for v in px]
    cells = color_img.resize((px_w, px_h), Image.BILINEAR).load()
    per_cell: list[list[tuple[str, int | None]]] = []
    for by in range(0, px_h, 4):
        crowns: list[tuple[str, int | None]] = []
        for bx in range(0, px_w, 2):
            bits = 0
            rs = gs = bs = n = 0
            for dx, dy, mask in (
                (0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04),
                (1, 0, 0x08), (1, 1, 0x10), (1, 2, 0x20),
                (0, 3, 0x40), (1, 3, 0x80),
            ):
                if dots[(by + dy) * px_w + bx + dx]:
                    bits |= mask
                    r, g, b, a = cells[bx + dx, by + dy]
                    if a >= 128:
                        rs += r
                        gs += g
                        bs += b
                        n += 1
            ch = chr(0x2800 + bits)
            crowns.append((ch, rgb_to_xterm(rs // n, gs // n, bs // n) if n else None))
        crowns = crowns_up_to(crowns, rstrip_len(crowns))
        per_cell.append(crowns)
    # Same blank-row trimming as to_braille().
    while per_cell and not any(ch.strip(BLANK) for ch, _ in per_cell[0]):
        per_cell.pop(0)
    while per_cell and not any(ch.strip(BLANK) for ch, _ in per_cell[-1]):
        per_cell.pop()
    rows: list[str] = []
    for crowns in per_cell:
        row, cur = "", None
        for ch, color in crowns:
            if color is None:
                if cur is not None:
                    row += "\x1b[0m"
                    cur = None
                row += ch
            else:
                if color != cur:
                    if cur is not None:
                        row += "\x1b[0m"
                    row += f"\x1b[38;5;{color}m"
                    cur = color
                row += ch
        if cur is not None:
            row += "\x1b[0m"
        rows.append(row)
    for row in rows:
        stripped = strip_sgr(row)
        if len(stripped) > MAX_COLS:
            raise SystemExit(f"row wider than {MAX_COLS} cells")
        for ch in stripped:
            if not 0x2800 <= ord(ch) <= 0x28FF:
                raise SystemExit(f"non-braille char in color art: {ch!r}")
    return rows


def rstrip_len(crowns: list[tuple[str, int | None]]) -> int:
    """Mono-equivalent right trim: count cells before trailing blanks."""
    n = len(crowns)
    while n and crowns[n - 1][0] == BLANK:
        n -= 1
    return n


def crowns_up_to(crowns: list[tuple[str, int | None]], n: int):
    return crowns[:n]


def check_color_file(path: Path, mono_path: Path) -> None:
    """Validate a `.color.txt` sidecar against its mono twin."""
    text = path.read_text(encoding="utf-8")
    assert text.endswith("\n"), f"{path}: missing trailing newline"
    mono = mono_path.read_text(encoding="utf-8")
    assert strip_sgr(text) == mono, f"{path}: strip != mono {mono_path.name}"
    for line in text.split("\n"):
        if not line:
            continue
        stripped = strip_sgr(line)
        assert len(stripped) <= MAX_COLS, f"{path}: line wider than {MAX_COLS} cells"
        for ch in stripped:
            assert 0x2800 <= ord(ch) <= 0x28FF, f"{path}: non-braille char {ch!r}"
        for run in re.findall(r"\x1b\[([0-9;]+)m", line):
            assert run == "0" or run.startswith("38;5;"), f"{path}: bad SGR {run!r}"
            if run.startswith("38;5;"):
                n = int(run.split(";")[2])
                assert 16 <= n <= 255, f"{path}: xterm index out of range: {n}"


def to_braille(gray, cols: int) -> list[str]:
    """Render cols-wide braille cells; height follows the logo aspect."""
    from PIL import Image, ImageOps

    # Dark-on-transparent marks composited onto white would vanish; flip them.
    probe = gray.resize((8, 8), Image.BILINEAR)
    if sum(probe.tobytes()) / 64 < 128:
        gray = ImageOps.invert(gray)
    px_w, px_h = grid_size(gray, cols)
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
