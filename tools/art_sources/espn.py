"""ESPN site-API art source (unofficial API; respect rate limits)."""

from __future__ import annotations

import json
import time
import urllib.request

from . import Source, Team

BASE = "https://site.api.espn.com/apis/site/v2"

# Our league slug -> (ESPN sport, ESPN league, page limit).
# Leagues absent from this table (tennis, mma, racing, golf) have no team
# logos at ESPN; list_teams returns [] so a future source can fill the gap.
LEAGUES: dict[str, tuple[str, str, int]] = {
    "nfl": ("football", "nfl", 50),
    "ncaaf": ("football", "college-football", 1000),
    "nba": ("basketball", "nba", 50),
    "wnba": ("basketball", "wnba", 50),
    "ncaam": ("basketball", "mens-college-basketball", 1000),
    "ncaaw": ("basketball", "womens-college-basketball", 1000),
    "mlb": ("baseball", "mlb", 50),
    "nhl": ("hockey", "nhl", 50),
    "mls": ("soccer", "usa.1", 50),
    "epl": ("soccer", "eng.1", 50),
    "laliga": ("soccer", "esp.1", 50),
    "bundesliga": ("soccer", "ger.1", 50),
    "seriea": ("soccer", "ita.1", 50),
    "ligue1": ("soccer", "fra.1", 50),
    "ucl": ("soccer", "uefa.champions", 100),
}


class EspnSource(Source):
    name = "espn"

    def leagues(self) -> list[str]:
        return sorted(LEAGUES)

    def list_teams(self, league_slug: str) -> list[Team]:
        if league_slug not in LEAGUES:
            return []
        sport, league, limit = LEAGUES[league_slug]
        url = f"{BASE}/sports/{sport}/{league}/teams?limit={limit}"
        with urllib.request.urlopen(url, timeout=30) as resp:
            data = json.load(resp)
        time.sleep(0.3)  # be polite to the unofficial API
        out: list[Team] = []
        for entry in data["sports"][0]["leagues"][0]["teams"]:
            team = entry["team"]
            logos = team.get("logos", [])
            url = next(
                (logo["href"] for logo in logos if {"full", "default"} <= set(logo.get("rel", []))),
                logos[0]["href"] if logos else None,
            )
            if url is None:
                continue  # e.g. F1 constructors, some low NCAA divisions
            out.append(
                Team(
                    abbreviation=team.get("abbreviation", "").upper(),
                    name=team.get("displayName", ""),
                    logo_url=url,
                )
            )
        return [team for team in out if team.abbreviation]
