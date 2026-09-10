# sprts

sprts is a small server for live sports scores and schedules. `curl` gets
plain text, browsers get the same table in a minimal page with clickable
links, and scripts can use the versioned JSON API. The server does not use
accounts, ads, tracking, or client side JavaScript.

## Run it

Install the tools and start the server:

```sh
mise install
mise run serve
```

The server listens on port 8080. Open `http://localhost:8080/mlb` in a browser,
or run:

```sh
curl localhost:8080/mlb
curl localhost:8080/api/v1/mlb
curl 'localhost:8080/mlb?date=2026-09-06'
```

Set `PORT` or `SPRTS_PORT` to change the port. Set `SPRTS_HOST` to change the
listen address. The default address is `0.0.0.0`.

## Shell CLI

`tools/sprts.sh` is a dependency-free (`curl` only) shell function. Drop it
in `~/.local/bin/` as `sprts` (it runs directly) or source it from your rc
file, then register favorites:

```sh
cp tools/sprts.sh ~/.local/bin/sprts && chmod +x ~/.local/bin/sprts
export SPRTS_LEAGUE=mlb SPRTS_TEAM=PHI   # e.g. in .zshrc
```

```sh
sprts                  # home: every league today
sprts mlb              # scoreboard
sprts mlb phi          # team page
sprts mlb 401816856    # one game (digits = game id)
sprts mlb tomorrow     # any date word or YYYY-MM-DD
sprts team             # $SPRTS_LEAGUE/$SPRTS_TEAM
sprts watch mlb        # re-curl every 15s until Ctrl-C
sprts --json mlb       # /api/v1/... instead of text
```

For push-style updates instead of polling, stream server-sent events:

```sh
curl -N 'https://sprts.horv.co/mlb?stream=sse'
```

## Run it with Docker

```sh
docker build -t sprts .
docker run --rm -p 8080:8080 sprts
```

The image contains the certificate bundle needed to call ESPN over HTTPS. The
`/healthz` route returns HTTP 200 when the server can accept requests.

## Deploy it on Cloudflare

The Cloudflare entry point runs the same Zig server in a Workers Container. It
does not contain a second application backend.

```sh
mise exec -- npm install
mise exec -- npm run cf:check
mise exec -- npm run cf:deploy
```

The checked in Wrangler configuration maps the Worker to `sprts.horv.co`.
Cloudflare Containers require a Workers Paid plan on the target account.

## Routes

`/{league}` and `/` return plain text to terminal clients and a minimal
HTML page with clickable links to browsers. Use the `date=YYYY-MM-DD`
query parameter to select a date. The `/api/v1/{league}` route always
returns JSON, and `/api/v1/leagues` lists the supported league slugs.
`/{league}/{id}` (all digits) is one game with linescore and scoring
plays, and `/{league}/{abbr}` is one team's last result and upcoming
schedule; both serve JSON under `/api/v1/` too. The machine-readable
spec is generated from the server source and served at `/openapi.json`.

Use `?format=text` or `?format=html` to force a format. The response
also honors `Accept: application/json` for scripts. ANSI color is on by
default for text output. Use `?color=0` to turn it off.

## Repository layout

- `apps/server` contains the HTTP server and ESPN adapter.
- `packages/core` contains provider independent sports types.
- `clients/espn` contains the generated and independently installable client.
- The public API spec is generated from `apps/server/src/spec.zig`
  (zchema is the single source of truth) and served at `/openapi.json`.

Each package has its own `build.zig` and `build.zig.zon`. You can build and test
it without the other app code. Run `mise run check` at the repository root to
check all packages.

## Update the ESPN client

The client is generated from the checked in ESPN OpenAPI document. Run:

```sh
mise run generate:espn
```

The task uses the mise managed openapi2zig 0.5.6 release. The generator skips
the output file when its checksum has not changed.

The ESPN API and OpenAPI document are unofficial. ESPN can change the service
without notice. Follow ESPN's terms and rate limits when you run this service.

## Add a league or provider

Add a league entry in `packages/core/src/leagues.zig`, then add its ESPN keys in
`apps/server/src/provider.zig`. A new provider implements the same operation as
`EspnAdapter.fetch` and returns a `core.domain.Scoreboard`. Routes and renderers
do not depend on ESPN response types.

## License

sprts is available under the MIT License. See `LICENSE`.
