"""Team-logo art sources. Adapter protocol for current and future providers.

A source answers one question: for a league slug, which teams have logos
and where are they? Conversion to marks lives in tools/art_convert.py and
is source-agnostic.

Protocol: implement list_teams(league_slug) -> list[Team] (empty list when
the source has nothing for that league -- e.g. ESPN has no team logos for
tennis or MMA). Register in REGISTRY under a --source name.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Team:
    abbreviation: str  # ESPN-style abbrev, e.g. "PHI"
    name: str  # display name, e.g. "Philadelphia Phillies"
    logo_url: str | None = None  # remote image, or None with logo_path
    logo_path: str | None = None  # local image file


class Source:
    name: str = "base"

    def list_teams(self, league_slug: str) -> list[Team]:
        raise NotImplementedError


def get_source(name: str) -> Source:
    from . import espn, local

    registry: dict[str, Source] = {
        espn.EspnSource.name: espn.EspnSource(),
        local.LocalSource.name: local.LocalSource(),
    }
    try:
        return registry[name]
    except KeyError:
        raise SystemExit(f"unknown source {name!r}; choices: {sorted(registry)}")
