#!/usr/bin/env bash
set -euo pipefail

# Record demo/sprts.tape to assets/demo.gif.
# Starts a local server for the curl, TUI, and SSE scenes, then stops it.
cd "$(dirname "$0")/.."
mkdir -p assets
mise exec -- zig build -Doptimize=ReleaseFast
(cd apps/cli && mise exec -- zig build -Doptimize=ReleaseFast)
export PATH="$PWD/zig-out/bin:$PWD/apps/cli/zig-out/bin:$PATH"
./zig-out/bin/sprts >/tmp/sprts-demo.log 2>&1 &
server=$!
trap 'kill $server' EXIT
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null http://localhost:8080/healthz; then break; fi
    sleep 0.5
done
# vhs is not in this repo's mise.toml, so pin the locally installed copy.
# (pts gets it from its own .mise.toml; same binary either way.)
mise exec vhs@0.11.0 ttyd@1.7.7 -- vhs demo/sprts.tape
