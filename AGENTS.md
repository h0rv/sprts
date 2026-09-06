# AGENTS.md

Zig 0.16.0 monorepo (`mise.toml` pins `zig 0.16.0`, `node 24.15.0`, `openapi2zig 0.5.6`). Use `mise install` then `mise run` / `mise exec --` so the pinned toolchain is used.

## Commands

- `mise run serve` — run server locally (`zig build run`), port 8080.
- `mise run check` — full verification: root `zig build test` + `zig build` + `ReleaseSafe` build + per-package `test`/`build` in `packages/core`, `clients/espn`, `apps/server`. Run this before declaring done; root `zig build test` alone only covers the server module.
- Focused: `cd packages/core && zig build test`, `cd clients/espn && zig build test`, `cd apps/server && zig build test` (or `zig build run` from `apps/server`).
- `mise run generate:espn` — regenerate ESPN client via `tools/generate-espn-client`.
- Cloudflare (thin wrapper, not a second backend): `mise exec -- npm install`, `mise exec -- npm run cf:check` (`tsc --noEmit` + `wrangler deploy --dry-run`), `mise exec -- npm run cf:deploy`. Containers require Workers Paid plan; config in `wrangler.jsonc` maps to `sprts.horv.co`.

## Layout

- `apps/server/src/main.zig` — native entrypoint (`std.http.Server`, `std.Io`, threaded accept loop, per-request arena). `root.zig` re-exports `provider` / `render` / `router` / `spec`.
- `apps/server/src/worker.zig` — stub WASM entry (`zig build wasm` via `workers-zig`); routing/fetch/render must reuse the native modules, not fork them.
- `packages/core` — provider-neutral `domain` / `leagues` / `date` types. `clients/espn` — generated ESPN client (`src/generated.zig`). Both are path dependencies with their own `build.zig`/`build.zig.zon` and are independently installable.
- `cloudflare/index.ts` — `SprtsContainer` (port 8080, `/healthz` ping) forwarding to the Docker image. `openapi/sprts-v1.json` is the public API served at `/openapi.json`.

## Gotchas

- Env: `PORT` or `SPRTS_PORT` (default 8080), `SPRTS_HOST` (default `0.0.0.0`), `SPRTS_ESPN_BASE_URL` (tests override ESPN; default `https://site.api.espn.com/apis/site/v2`). Docker image needs `ca-certificates` for ESPN HTTPS.
- New league = two edits: entry in `packages/core/src/leagues.zig` + ESPN sport/league keys in `endpointFor` in `apps/server/src/provider.zig`. A test fails if a league lacks a mapping. Routes/renderers stay ESPN-agnostic and take `core.domain.Scoreboard`.
- Never hand-edit `clients/espn/src/generated.zig`; edit `clients/espn/openapi/site-api.json` (provenance in `UPSTREAM.md`; unofficial ESPN API, respect rate limits) and regenerate. Generator skips output when checksum is unchanged; it runs `zig fmt` on the result.
- Tests inject `EspnAdapter.transport` + `clock` (`FakeTransportState` in `provider.zig`) — do not hit live ESPN in tests.
- `zig-out/`, `.zig-cache/`, `zig-pkg/` are build artifacts; root `src/` is empty.
