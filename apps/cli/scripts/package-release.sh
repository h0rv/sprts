#!/usr/bin/env bash
set -euo pipefail

# Cross-compiles `sprts-tui` (ReleaseFast) and packs release tarballs plus
# SHA256SUMS into apps/cli/dist/ (mirrors pts package-release.sh, but builds
# every target in one run instead of one target per invocation).
#
# Usage:
#   apps/cli/scripts/package-release.sh [target ...]
#
# Defaults to x86_64-linux, aarch64-linux, aarch64-macos. Override the
# optimize mode with OPTIMIZE= (default ReleaseFast). Each tarball holds a
# top-level sprts-tui-<target>/ dir with the binary, README.md, and LICENSE
# — the layout apps/cli/scripts/install.sh expects.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$(dirname "$CLI_DIR")")"
DIST_DIR="$CLI_DIR/dist"

targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
  targets=(x86_64-linux aarch64-linux aarch64-macos)
fi

optimize="${OPTIMIZE:-ReleaseFast}"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

for target in "${targets[@]}"; do
  echo "building $target ($optimize)"
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  (cd "$CLI_DIR" && zig build -Dtarget="$target" -Doptimize="$optimize" --prefix "$stage/prefix")
  name="sprts-tui-${target}"
  root="$DIST_DIR/$name"
  mkdir -p "$root"
  cp "$stage/prefix/bin/sprts-tui" "$root/"
  cp "$CLI_DIR/README.md" "$REPO_ROOT/LICENSE" "$root/"
  tar -C "$DIST_DIR" -czf "$DIST_DIR/${name}.tar.gz" "$name"
  rm -rf "$root" "$stage"
  trap - RETURN
done

(cd "$DIST_DIR" && sha256sum sprts-tui-*.tar.gz > SHA256SUMS)
echo "wrote $DIST_DIR:"
ls "$DIST_DIR"
