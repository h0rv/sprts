# sprts-server

The HTTP application. It depends only on the public APIs of `sprts-core` and
the generated `espn-client` packages.

From this directory, run `zig build run`, or use `zig build run` at the
monorepo root. Configuration is through `PORT`, `SPRTS_HOST`, and the optional
`SPRTS_ESPN_BASE_URL`.

