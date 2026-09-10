# sprts

Live sports scores as plain text, HTML, and JSON, from one server.

![demo](assets/demo.gif)

## Try it

No install needed. The live server answers curl and browsers alike.

```sh
curl https://sprts.horv.co/mlb
curl 'https://sprts.horv.co/mlb?date=2026-09-06'
curl https://sprts.horv.co/api/v1/mlb
curl -N 'https://sprts.horv.co/mlb?stream=sse'
```

## Interfaces

* Web: open `https://sprts.horv.co/mlb` in a browser for the same scores with clickable links.
* TUI: `sprts-tui` puts the scores in your terminal, with keys to move, change days, and open games.
* API: `/api/v1/mlb` returns the same board as JSON, and `/openapi.json` describes every route.
* SSE: `?stream=sse` streams the text board for `curl -N`, and `/mlb/tour` plays that stream in a browser terminal.

## Shell client

`tools/sprts` needs only curl. Copy it to your path:

```sh
install -m755 tools/sprts ~/.local/bin/sprts
sprts mlb
sprts mlb 2026-09-06
sprts mlb --watch
```

## TUI client

Linux or macOS, installs to `~/.local/bin/sprts-tui`:

```sh
curl -fsSL https://raw.githubusercontent.com/h0rv/sprts/main/apps/cli/scripts/install.sh | sh
```

```sh
sprts-tui                  # full screen when output is a terminal
sprts-tui mlb              # one league
sprts-tui mlb --plain      # print and exit
sprts-tui --date tomorrow  # another day
```

Keys: j and k move, h and l change the day, enter opens a game or team, s shows standings, slash filters, r refreshes, q quits.

## Run the server

```sh
mise install
mise run serve
```

The server listens on port 8080. Set `PORT` or `SPRTS_PORT` to change it, and `SPRTS_HOST` to change the address. With Docker:

```sh
docker build -t sprts .
docker run --rm -p 8080:8080 sprts
```

`/healthz` returns 200 when the server is up.

## Routes

* `/` and `/all`: every league today.
* `/{league}`: one scoreboard, as in `/mlb`.
* `/{league}/{id}`: one game, with linescore and plays.
* `/{league}/{abbr}`: one team, as in `/mlb/phi`.
* `/{league}/standings`: the current table.
* `/api/v1/...`: the same shapes as JSON.
* `/openapi.json`, `/docs`, `/llms.txt`: spec, reference, and agent guide.
* `/:help`: the full route and flag list, in the terminal too.

Flags: `?date=YYYY-MM-DD`, `?week=N` for football, `?0` for one line output, `?format=text|html`, `?color=0`, `?art=off`, `?stream=sse`. Date words like `today` and `tomorrow` also work.

## Docs

* Live reference: `https://sprts.horv.co/docs`
* Agent guide: `https://sprts.horv.co/llms.txt`
* Streaming: `docs/STREAMING.md`
* Rendering: `docs/RENDERER.md`
* TUI client: `apps/cli/README.md`

## Develop

```sh
mise run check
mise run generate:espn
```

`mise run check` builds and tests every package. Scores come from ESPN through a generated client, so regenerate it after the OpenAPI file changes. See `AGENTS.md` for the full notes.

## License

MIT. See `LICENSE`.
