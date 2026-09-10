#!/usr/bin/env sh
set -eu

# Installs `sprts-tui` from GitHub releases (mirrors pts install.sh).
#
#   curl -fsSL https://raw.githubusercontent.com/h0rv/sprts/main/apps/cli/scripts/install.sh | sh
#
# Env overrides:
#   SPRTS_TUI_VERSION     release tag, or "latest" (default: latest)
#   SPRTS_TUI_ARCHIVE_URL full URL to a sprts-tui-<arch>-<os>.tar.gz (default:
#                         derived from the version + detected platform)
#   PREFIX                install prefix (default: $HOME/.local;
#                         the binary lands in $PREFIX/bin/sprts-tui)

repo="${SPRTS_TUI_REPO:-h0rv/sprts}"
version="${SPRTS_TUI_VERSION:-latest}"
prefix="${PREFIX:-$HOME/.local}"
bin_dir="$prefix/bin"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  linux) os="linux" ;;
  darwin) os="macos" ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

case "$arch" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

asset="sprts-tui-${arch}-${os}.tar.gz"
if [ "${SPRTS_TUI_ARCHIVE_URL:-}" ]; then
  url="$SPRTS_TUI_ARCHIVE_URL"
elif [ "$version" = "latest" ]; then
  url="https://github.com/$repo/releases/latest/download/$asset"
else
  url="https://github.com/$repo/releases/download/$version/$asset"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$bin_dir"
echo "downloading $url"
curl -fsSL "$url" -o "$tmp/sprts-tui.tar.gz"
tar -xzf "$tmp/sprts-tui.tar.gz" -C "$tmp"
install -m 0755 "$tmp/sprts-tui-${arch}-${os}/sprts-tui" "$bin_dir/sprts-tui"

echo "installed $bin_dir/sprts-tui"
echo "run: sprts-tui --help"
