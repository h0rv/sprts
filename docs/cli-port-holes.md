# CLI-port holes: `/api/v1` vs a full TUI client (pts feature set)

RESEARCH ONLY — no code changed. Sources read: `apps/server/src/spec.zig`
(single source of truth), `packages/core/src/{domain,detail,schedule,standings,leagues,date}.zig`,
`apps/server/src/{router,provider,digest,detail_view,team_view,standings_view}.zig`,
and the reference TUI `pts/src/{cli,model,parser,routes,ui,main}.zig`.
No live ESPN calls; no sprts.horv.co calls were needed (spec + source sufficed).

## What pts needs (feature inventory)

- Scoreboards by league+date (`--date YYYY-MM-DD`, `h`/`l` prev/next day via date links)
- Game detail (enter opens game URL: linescore, probable pitchers, lineups,
  box score, scoring summary)
- Team view + schedule (`schedule` shortcut; team pages: last results, live game, upcoming)
- Standings (`standings` shortcut per sport)
- Teams pages (`teams` shortcut: per-sport team list → team picker)
- Digest/all-leagues (`all` sport → `/all/{date}/`)
- Filter/search (`/` matches title, status text, league name, client-side)
- Auto-refresh (`--refresh`, `a` toggle; polling + cache fallback, client-side)
- Game rows show: league, status chip, matchup title, score or start time, **network**

## Our `/api/v1` surface (from spec.zig)

| Operation | Path | Response |
|---|---|---|
| listLeagues | `GET /api/v1/leagues` | `LeagueList{slug,name,sport}` |
| getAll | `GET /api/v1/all?date=` | `DigestJson{date,leagues: Scoreboard[],degraded: string[]}` |
| getScoreboard | `GET /api/v1/{league}?date=&week=` | `Scoreboard` |
| getGame | `GET /api/v1/{league}/{id}` (digits only) | `DetailGame` |
| getTeam | `GET /api/v1/{league}/{abbr}` | `ScheduleTeamView` |
| getStandings | `GET /api/v1/{league}/standings` | `LeagueStandings` |

`Scoreboard.Game` = `{id,name,starts_at,state,status,participants[]}`;
`Participant` = `{id,name,abbreviation,score,winner,home_away?,record?}`.
`DetailGame` adds `venue?,attendance?,series?,situation?,decisions[],scoring_plays[],leaders[],lineups[],team_stats[]`.
`ScheduleTeamView` = `{team,last[≤5],next[≤5],live?,extra_past[],extra_next[]}`.
JSON renderers emit the full structs (text-only `?height` caps do not apply to JSON).

## Holes

| HOLE | IMPACT | SEVERITY | PROPOSED FIX |
|---|---|---|---|
| H1 — No team-list endpoint. Router has no `/{league}/teams` route and spec has no `listTeams` operation; the only path to `getTeam` is a caller-supplied `abbr`. pts has a `teams` shortcut per sport (team picker → schedule). | CLI cannot offer team selection/schedule browsing without shipping a hardcoded ~600-team roster that rots on relocations/rebrands. | blocks-port | Server: add `GET /api/v1/{league}/teams` returning `[{id,abbrev,name}]` (ESPN teams endpoint per sport/league keys already in `endpointFor`). CLI workaround: hardcode abbrevs per league (fragile, drifts). |
| H2 — No broadcaster/network in JSON. `Scoreboard.Game` and `DetailGame` carry no TV field; provider drops ESPN `broadcasts`/`geoBroadcasts` (present in `site-api.json` payload, §§2435/5765/6954) during normalization. pts game rows render a network column (`Game.network`, matched against ESPN/ABC/FOX/TNT/…) and it is the one per-row field our JSON cannot reproduce. | Game-list parity impossible: network column must be dropped or left blank in the port. | blocks-port | Server: add `broadcasts: string[]` (or `network: string|null`) to `domain.Game` + `detail.DetailGame`, populated from competition `broadcasts[].names` / `geoBroadcasts` in provider. CLI workaround: none — data never reaches the wire (could scrape text render, not acceptable for a JSON client). |
| H3 — No venue/attendance on scoreboard rows. Only `DetailGame` carries `venue?`/`attendance?`; list rows have neither. | TUI showing venue per row (or sorting/filtering by it) costs N detail fetches per board. pts list rows don't show venue, so parity survives — extra fetches only if the port wants more. | nice-to-have | Server: add optional `venue?` to `domain.Game` (provider already parses it for detail). CLI workaround: lazy-fetch `getGame` for the selected row only. |
| H4 — Standings coverage not discoverable; 5 leagues 404. `standingsSupported` allows football/basketball/baseball/hockey/soccer only, so `atp/wta/f1/ufc/pga` return 404 ("standings unavailable"), and `/api/v1/leagues` carries no capability flags. pts offers `standings` for every sport page. | CLI must probe each league and handle 404 (or hardcode the 5 exclusions); no machine-readable signal. | nice-to-have | Server: add `capabilities{standings: bool, week: bool}` per entry in `LeagueList` (covers H5 too). CLI workaround: treat 404 as "no table", cache the exclusion set. |
| H5 — Week semantics undiscoverable + partly unpinned. `?week=N` is honored only for football (`nfl`, `ncaaf`) and silently ignored elsewhere; nothing machine-readable names the football set; `/api/v1/all` accepts no `week` (date-only digest, by design); `?week=`+`?date=` combined behavior (URL carries both `dates=` and `week=`) is unpinned against live ESPN. | NFL/NCAAF week navigation works but the CLI hardcodes which slugs accept `week`; prev/next-week UX has no server guidance, and non-football `?week=` fails silently rather than 400ing. | nice-to-have | Server: capability flag (see H4) + document week+date precedence in the `getScoreboard` description; consider 400 on `?week=` for non-football instead of silent ignore. CLI workaround: hardcode `nfl+ncaaf`, never send `week` with `date`. |
| H6 — No JSON twins for game aliases. `/{league}/{YYYY-MM-DD}/{away}-{home}`, `/.../week{N}/...`, and `/{league}/{abbr}/today` are human redirects; only `today` preserves the address family (`TodayRoute.api`), date/week aliases are explicitly no-twin ("JSON keeps ids"). | JSON client resolving "today's MIN-DET game" fetches the date board and matches `participants[].abbreviation` itself (robust — abbrevs are on the row — but extra request + matching code vs one redirect-follow). | nice-to-have | Server: add `/api/v1/` twins returning `307` to the canonical `getGame` address (or a `resolveGame` operation). CLI workaround: `getScoreboard?date=` + abbrev match; follow the human 302 as fallback. |
| H7 — League-shape mismatch with pts. pts has one `soccer` page and one `ncaamb` (`/college-basketball/`); we have 6 soccer leagues (`mls/epl/laliga/bundesliga/seriea/ligue1/ucl`) and split `ncaam`/`ncaaw` (pts `ncaamb` ≈ our `ncaam`, name differs). No aggregate soccer board exists outside `/api/v1/all`. | Port needs a mapping table (`ncaamb→ncaam`; `soccer→` 6 slugs or `/all` filtered to `sport=="Soccer"`) plus UX choice for soccer aggregation. | nice-to-have | Server: nothing required (`/all` + `sport` field already enables the fan-out). CLI workaround: map table + aggregate client-side from `getAll`. Optional server nicety: `?sport=` filter on `getAll`. |
| H8 — Thin standings columns. `StandingEntry` = W/L/T/PTS display strings only; no games-behind, streak, pct, home/away splits. Text view renders `W-L[-T]` + optional `PTS`. | A standings screen matching richer upstream tables (GB, streak) cannot be built; W-L + points only. | nice-to-have | Server: add optional `games_behind?`, `streak?`, `pct?` to `StandingEntry` (ESPN `standings.entries[].stats` carries them). CLI workaround: show W-L/PTS only. |
| H9 — No structured clock/period on rows. Live state arrives as `state="in"` + free-text `status` ("Top 7th"); no `clock`/`period` fields on `domain.Game` (detail has `situation` only when the provider supplies matchup data). | TUI cannot sort by time-remaining, show a countdown, or align periods without parsing English. pts has the same limitation (parses `status_text`), so parity holds. | nice-to-have | Server: add `clock?`/`period?` display strings to `domain.Game` from `status.type`/`competition.status`. CLI workaround: same string parsing pts does. |
| H10 — Team view is relative-to-today only. `getTeam` takes no `date`; `last/next/extra_*` window around now. No as-of-date schedule browsing. | Port cannot show "PHI's schedule as of June" or a past-date team page; pts team pages are current-only too, so parity holds. | nice-to-have | Server: optional `?date=` on `getTeam` shifting the last/next split point. CLI workaround: none needed for parity; full season already arrives via `extra_past/extra_next`. |

## Explicitly checked, NOT holes

- **Date tokens in JSON**: `today/tomorrow/yesterday` parse on `/api/v1/{league}` and `/api/v1/all` (router tests pin both twins); server resolves against the request day. Game/team/standings are id- or current-addressed, correctly dateless.
- **Records on scoreboard rows**: `Participant.record` populated from ESPN `records[type=total].summary` (provider test pins `69-74`; detail falls back to the board record when pre-game summaries omit it). Absent only where meaningless (tennis/golf/racing/MMA athlete sides).
- **Digest `degraded`**: machine-readable (`degraded: string[]`, always emitted); zero-games + absent = off-day, + present = outage. JSON digest is uncapped (text `?height` cap doesn't apply). Nit (not a hole): degraded zero-game boards hardcode `source: "site.api.espn.com"` and carry no error kind.
- **Game `id` stability**: ESPN event ids are global/stable; detail is id-addressed with no date param, and `DetailGame` echoes its `date`. Cross-day lookups are safe; see H6 for the only gap (matchup→id resolution).
- **Detail depth vs pts game page**: probable starters (`probable`), batting `lineups`, box-score `team_stats`, `scoring_plays`, `leaders`, `situation`, `decisions` (W/L/SV), `series` — all present in `DetailGame` JSON. Full parity achievable (minus H2 broadcast).
- **Schedule depth**: `last/next` capped at 5 but `extra_past/extra_next` carry full-season overflow — no hole for a schedule screen.
- **Filter/search, auto-refresh, cache fallback, `--plain`, open-in-browser**: pure client-side in pts (local match, polling loop, disk cache) — no server support needed. Note: live JSON updates = poll (`?stream=sse` is text-only); 15s poll of `getScoreboard`/`getAll` is the correct port behavior.
- **Error contract**: bad `date` → 400 on the two date-driven JSON endpoints; unknown league → 404; upstream loss → 502 (single) or `degraded` entry (digest). All machine-readable via `z.ErrorBody` + status codes.
