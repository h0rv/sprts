# Renderer

Every page a person reads returns plain text or a minimal page around the
same table. Scripts use the JSON API under `/api/v1/`. Rendering changes
never alter JSON field names.

## Formats and routes

- Three formats exist: `text`, `html`, and `json`.
- `/{league}` and `/` return text for terminal clients and a minimal HTML
  page for browsers. The HTML page holds the same table inside a `pre`
  block plus links for date navigation, today, and the JSON API. It never
  carries ANSI escapes.
- `/api/v1/{league}` and `/api/v1/leagues` return `application/json`.
- `/openapi.json` returns `application/json`. `/healthz` returns `text/plain`.
- The address decides first, then an explicit `?format=text` or
  `?format=html`, then the Accept header. Browsers send `text/html` and
  get the HTML page. No User-Agent sniffing happens.
- Responses carry `Vary: accept`. `cache-control` and `nosniff` are sent.
- Errors under `/api/v1/` return JSON. All other errors match the request
  format.

## Text layout

Each scoreboard is one fixed width table with `|` pipes and box rules.
Each game has a status row plus one row per entrant in the form
`ABBR | Name | Score`, and the winner carries its mark. The status row
shows the provider status text verbatim, colored from `Game.state`
(`in` reads live, `pre` reads upcoming). Entrants render in provider
order.

Names truncate at the column width with `…`. Truncation never splits a
code point, because a byte cut can emit invalid output. Padding counts
bytes, so Latin names align and wide glyphs can shift the rules. Lines
never wrap. The footer is plain date navigation of the form
`/{slug}?date=YYYY-MM-DD` for the previous and next day. A day with no
games prints `No games scheduled.`

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

## Time zone

A missing `?date` resolves to the US Eastern calendar day (EST/EDT by
the US DST rule: second Sunday of March to first Sunday of November),
matching ESPN and plaintextsports, so US night games never flip a day
early. `?tz=ET|UTC` (plus `EST`, `EDT`, `America/New_York`, `GMT`, `Z`,
`Etc/UTC`, or a fixed `[+-]H[H][:MM]` offset) overrides it; an invalid
`?tz=` is ignored, never a 400. Date labels name their zone (`9/6 ET`).

## Code shape

- `router.parse` takes the request target only. `router.formatFor` takes
  the target and the Accept header. `Route.home` carries the color flag.
  `ScoreboardRoute` carries league, date, color, and terminal width and
  height.
- `render.text` takes the allocator, the board, and a color flag.
  `render.home` takes the allocator and a color flag. `render.scoreHtml`
  and `render.homeHtml` take no color flag and never emit escapes.
  `render.errorBody` takes the allocator, the message, and the format.
- `main.respond` serves `text/plain`, `text/html`, and `application/json`.
- Responses render from the cached board. Render flags stay out of the
  cache key.

## Tests

- `mise run check` passes.
- Table borders are present and rows share one display width.
- ANSI is present by default and absent with `?color=0`.
- HTML pages carry links and zero escape bytes.
- JSON outputs validate through the shared `render.validatedJson` gate,
  and the served `/openapi.json` (generated from `spec.zig` via zchema)
  covers every `/api/v1/` JSON route.
