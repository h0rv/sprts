# sprts-tui

Live sports scores in your terminal. Interactive TUI by default, one-shot
text output when piped.

## Install

Linux/macOS (installs to `~/.local/bin/sprts-tui`):

```sh
curl -fsSL https://raw.githubusercontent.com/h0rv/sprts/main/apps/cli/scripts/install.sh | sh
```

From source (Zig 0.16.0 via mise):

```sh
mise install
cd apps/cli && zig build -Doptimize=ReleaseFast --prefix ~/.local
```

Release tarballs (`sprts-tui-<arch>-<os>.tar.gz`) and `SHA256SUMS` are built
with `scripts/package-release.sh` and published to GitHub releases. A
Homebrew formula can be generated with
`scripts/generate-homebrew-formula.sh v0.1.0 dist`.

## Usage

```sh
sprts-tui                  # TUI when stdout is a TTY, one-shot otherwise
sprts-tui mlb              # one league
sprts-tui mlb --plain      # print today's board and exit
sprts-tui --date tomorrow  # every league, tomorrow
sprts-tui nfl --date 2026-09-06 --json   # raw API body and exit
sprts-tui --tui            # force the interactive loop
sprts-tui --host http://localhost:8080 mlb   # local server
sprts-tui --help
```

## Keys (TUI)

| Key         | Action              |
| ----------- | ------------------- |
| j / down    | Move down           |
| k / up      | Move up             |
| h / left    | Previous day        |
| l / right   | Next day            |
| enter       | Open game or team   |
| b / esc     | Back                |
| s           | Standings           |
| /           | Filter              |
| r           | Refresh             |
| a           | Toggle auto-refresh |
| ?           | This help           |
| q           | Quit                |

Views: leagues picker -> scoreboard -> game detail -> team schedule, plus
standings off `s`. `enter` opens the selected row (a game, or a team row
inside game/standings); `b` pops back.

## `--plain` / SSE behavior

- `--plain` prints a compact text scoreboard and exits (the default one-shot
  mode when stdout is not a TTY). `--json` dumps the raw API response body
  instead. `--tui` forces the interactive loop and errors out when stdout is
  not a terminal.
- In the TUI, live boards and live games auto-refresh from the server SSE
  stream (`/{league}?stream=sse`, Accept: `text/event-stream`) while auto is
  on; anything else polls on refresh. Toggle with `a` (on by default),
  refresh cadence is 15s. A failed or empty SSE read falls back to plain
  polling. The one-shot modes never use SSE — they fetch the JSON API once.

## Config / env

| Flag / env              | Meaning                                              |
| ----------------------- | ---------------------------------------------------- |
| `--host URL`            | API base URL (default: `https://sprts.horv.co`)      |
| `--date DATE`           | `YYYY-MM-DD`, `today`, `tomorrow`, `yesterday`       |
| `PREFIX`                | Install prefix for `scripts/install.sh` (default: `~/.local`; binary lands in `$PREFIX/bin`) |
| `SPRTS_TUI_VERSION`     | Release tag for the installer, or `latest` (default) |
| `SPRTS_TUI_ARCHIVE_URL` | Full tarball URL for the installer (skips version/platform detection) |
| `SPRTS_TUI_REPO`        | `owner/repo` for installer + formula URLs (default: `h0rv/sprts`) |
| `OPTIMIZE`              | Zig optimize mode for `scripts/package-release.sh` (default: `ReleaseFast`) |
