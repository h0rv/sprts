# Renderer

Every page a person reads returns plain text. Scripts use the JSON API
under `/api/v1/`. Rendering changes never alter JSON field names.

## Formats and routes

- Two formats exist: `text` and `json`.
- `/{league}` and `/` return `text/plain` for every client.
- `/api/v1/{league}` and `/api/v1/leagues` return `application/json`.
- `/openapi.json` returns `application/json`. `/healthz` returns `text/plain`.
- The address alone decides the bytes. Headers change nothing.
- No `vary` header is sent. `cache-control` and `nosniff` are sent.
- Errors under `/api/v1/` return JSON. All other errors return text.

## Text layout

Each scoreboard is one fixed width table with `|` pipes and box rules.
Each game has a status row plus one row per entrant in the form
`ABBR | Name | Score`, and the winner carries its mark. The status prefix
comes from `Game.state` (`pre`, `in`, `post`) with the start time from
`starts_at`, and entrants keep provider order unless `home_away` says
otherwise.

Names truncate at the column width with `…`. Truncation walks code
points and pads by display width, because a byte cut can split a letter
and shift the rules. Lines never wrap. The footer is plain date
navigation of the form `/{slug}?date=YYYY-MM-DD` for the previous and
next day. A day with no games prints `No games scheduled.`

## Color

ANSI is on by default. Live lines are bold red, winners are green,
upcoming lines are dim yellow, and headers are dim. Pipes and rules stay
uncolored so stripped output pipes cleanly. When color is off, output
contains zero escape bytes.

`?color=0` turns color off and `?color=1` forces it on, with exact values
only. When the address has no flag, the server default applies, and the
server reads it once at startup from `NO_COLOR` and `TERM`. A remote
client env never reaches the server, so the flag is the only remote
switch.

## Code shape

- `router.parse` takes the request target only. `Route.home` carries no
  payload. `ScoreboardRoute` carries league and date only.
- `render.text` takes the allocator, the board, and a color flag.
  `render.home` takes the allocator and a color flag. `render.errorBody`
  takes the allocator, the message, and the format.
- `main.respond` serves `text/plain` and `application/json` only.
- Responses render from the cached board. Render flags stay out of the
  cache key.

## Tests

- `mise run check` passes.
- Table borders are present and rules stay aligned on long names.
- ANSI is present by default and absent with `?color=0`.
- No response contains `<html`.
- JSON fields validate against `openapi/sprts-v1.json`.
