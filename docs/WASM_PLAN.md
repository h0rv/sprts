# WASM plan

## Current state
- Non-wasm server: native `sprts` exe serving `std.http.Server`
  (`apps/server/src/main.zig`), deployed via container
  (`wrangler.jsonc` top level, `cloudflare/index.ts`, `Dockerfile`).
- ESPN reads go through `std.http.Client` (`clients/espn/src/root.zig`
  `getScoreboardRaw`, generated client), with a curl UA override.
  `EspnAdapter` (`apps/server/src/provider.zig`) owns `io` + client
  construction; `parseAndNormalize` is pure JSON → `core.domain`.
- Portable logic: `router.parse(target, accept, user-agent)`
  (`apps/server/src/router.zig:22`), `render.text/html/json`
  + `leaguesJson`/`home`/`errorBody`, `spec.openApiJson` (`z.Spec`),
  `core.date` except `today(alloc, io)` (`packages/core/src/date.zig:22`).
  `packages/core` has no third-party deps.
- Builds produce native exe only. No wasm target, no worker entrypoint.

## Target shape
- `packages/core`: unchanged, dependency-free, portable.
- `clients/espn`: exposes pure `buildScoreboardUrl`, shared pure
  `parseAndNormalize`, and an `HttpTransport` interface
  (`fetch(url, headers) -> {status, body}`).
  - Non-wasm `StdTransport`: existing `std.http.Client` path.
  - Wasm `WorkerTransport`: `workers.fetch` (JSPI sync-style).
- `provider.EspnAdapter`: takes `{transport, clock, base_url}`.
  `clock` supplies epoch seconds; `todayFromEpoch` replaces
  `today(alloc, io)`. Non-wasm passes `std.Io.Clock.real`, wasm passes
  `workers.now()/1000`.
- Worker entry `apps/server/src/worker.zig` (`pub fn fetch`): maps Worker
  request to `(target, accept, user-agent)`, calls `router.parse`,
  fetches via `WorkerTransport` + cache, renders with existing
  `render`/`spec`. Uses per-request `env.allocator`. Imports
  `workers-zig` and zchema `validation`/`openapi` granularly.
- Native `main.zig`, `Dockerfile`, and container path stay as-is.

## Edge cache
- Workers Cache API, keyed on normalized board (`league + date`).
- Canonicalization: resolve missing `?date` to a concrete day, lowercase
  slug, unify `/mlb` ≡ `/api/v1/mlb`, strip non-`date` query, never cache
  errors. All formats render from the cached board.
- TTL `max-age=30`; stale-on-upstream-error up to 300s, else 502.

## Build
- Add `nilslice/workers-zig` dependency (Zig 0.16, JSPI), imported only
  by the worker entry.
- New `zig build wasm`: `addWorker`, target `wasm32 + wasi`,
  `ReleaseSmall` → `worker.wasm + entry.js + shim.js` in `zig-out/bin`.

## Deploy
- Single `wrangler.jsonc`. Top level remains the non-wasm container.
- `env.wasm`: pure worker, `main` → built `entry.js`; omits
  `containers`/`durable_objects`/`migrations`; keeps
  `compatibility_date`, `compatibility_flags: [nodejs_compat]`,
  `observability`. Separate route from the container env.
- Scripts: `cf:deploy:wasm`, `cf:dev:wasm` (`wrangler ... --env wasm`).

## Verify
- `mise run check` green (native).
- `zig build wasm` succeeds.
- `wrangler dev --env wasm` parity with non-wasm on `/mlb`,
  `/api/v1/mlb?date=…`, `/openapi.json`, `/healthz` (curl + browser).
- Cache hit/miss and stale-on-error observed against ESPN.

## Risks
- Workers `fetch` UA/header restrictions vs ESPN's agent checks —
  re-verify custom UA + `accept: application/json`.
- Non-portable deps (`std.http.Client`, sockets, threads, clock) leaking
  into the worker path — caught by early `zig build wasm`.
- Dual-artifact wrangler build: one build command emits container +
  wasm outputs; `entry.js`/`worker.wasm`/`shim.js` deploy together.
