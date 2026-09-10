# AGENTS.md

Zig 0.16.0 monorepo (`mise.toml` pins `zig 0.16.0`, `node 24.15.0`, `openapi2zig 0.5.6`). Use `mise install` then `mise run` / `mise exec --` so the pinned toolchain is used.

## Commands

- `mise run serve` — run server locally (`zig build run`), port 8080. `mise run run:cli` — run the CLI (`apps/cli`, once landed).
- `mise run check` — full verification: root `zig build test` (server + sprts_client modules) + `zig build` + `ReleaseSafe` build + per-package `test` in `packages/core` and `clients/espn`, `test`+`build` in `clients/sprts`, `apps/server`, and `apps/cli` (the CLI step skips until `apps/cli` lands). Run this before declaring done; root `zig build test` alone does not cover the per-package steps.
- Focused: `cd packages/core && zig build test`, `cd clients/espn && zig build test`, `cd apps/server && zig build test` (or `zig build run` from `apps/server`).
- `mise run generate:espn` — regenerate ESPN client via `tools/generate-espn-client`. `mise run generate:sprts-client` — regenerate sprts API client via `tools/generate-sprts-client` (spins up a local server for `/openapi.json`; no checked-in spec).
- Cloudflare (thin wrapper, not a second backend): `mise exec -- npm install`, `mise exec -- npm run cf:check` (`tsc --noEmit` + `wrangler deploy --dry-run`), `mise exec -- npm run cf:deploy`. Containers require Workers Paid plan; config in `wrangler.jsonc` maps to `sprts.horv.co`.

## Layout

- `apps/server/src/main.zig` — native entrypoint (`std.http.Server`, `std.Io`, threaded accept loop, per-request arena). `root.zig` re-exports `provider` / `render` / `router` / `spec`.
- `apps/server/src/worker.zig` — stub WASM entry (`zig build wasm` via `workers-zig`); routing/fetch/render must reuse the native modules, not fork them.
- `packages/core` — provider-neutral `domain` / `leagues` / `date` types. `clients/espn` — generated ESPN client (`src/generated.zig`). Both are path dependencies with their own `build.zig`/`build.zig.zon` and are independently installable.
- `cloudflare/index.ts` — `SprtsContainer` (port 8080, `/healthz` ping) forwarding to the Docker image. The public API spec is generated from `apps/server/src/spec.zig` via zchema (single source of truth) and served at `/openapi.json`; there is no checked-in spec file.

## Gotchas

- Env: `PORT` or `SPRTS_PORT` (default 8080), `SPRTS_HOST` (default `0.0.0.0`), `SPRTS_ESPN_BASE_URL` (tests override ESPN; default `https://site.api.espn.com/apis/site/v2`). Docker image needs `ca-certificates` for ESPN HTTPS.
- New league = two edits: entry in `packages/core/src/leagues.zig` + ESPN sport/league keys in `endpointFor` in `apps/server/src/provider.zig`. A test fails if a league lacks a mapping. Routes/renderers stay ESPN-agnostic and take `core.domain.Scoreboard`.
- Never hand-edit `clients/espn/src/generated.zig`; edit `clients/espn/openapi/site-api.json` (provenance in `UPSTREAM.md`; unofficial ESPN API, respect rate limits) and regenerate. Generator skips output when checksum is unchanged; it runs `zig fmt` on the result.
- Tests inject `EspnAdapter.transport` + `clock` (`FakeTransportState` in `provider.zig`) — do not hit live ESPN in tests.
- `zig-out/`, `.zig-cache/`, `zig-pkg/` are build artifacts; root `src/` is empty.
