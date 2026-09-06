"""Local-directory art source. Proves the adapter; useful for leagues ESPN lacks.

Layout: <root>/<league>/<ABBREV>.png (also .jpg). Point --local-root at it.
"""

from __future__ import annotations

import os
from pathlib import Path

from . import Source, Team

IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp")


class LocalSource(Source):
    name = "local"

    def __init__(self, root: str | None = None) -> None:
        self.root = Path(root) if root else None

    def leagues(self) -> list[str]:
        if self.root is None or not self.root.is_dir():
            return []
        return sorted(p.name for p in self.root.iterdir() if p.is_dir())

    def list_teams(self, league_slug: str) -> list[Team]:
        if self.root is None:
            raise SystemExit("local source needs --local-root <dir>")
        league_dir = self.root / league_slug
        if not league_dir.is_dir():
            return []
        out: list[Team] = []
        for path in sorted(os.listdir(league_dir)):
            stem, ext = os.path.splitext(path)
            if ext.lower() not in IMAGE_EXTS or not stem:
                continue
            out.append(Team(abbreviation=stem.upper(), name=stem.upper(), logo_path=str(league_dir / path)))
        return out
