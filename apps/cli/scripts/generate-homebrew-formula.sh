#!/usr/bin/env bash
set -euo pipefail

# Prints a Homebrew formula for the sprts-tui release tarballs in a dist dir
# (mirrors pts generate-homebrew-formula.sh).
#
# Usage:
#   apps/cli/scripts/generate-homebrew-formula.sh v0.1.0 [dist-dir] > sprts-tui.rb
#
# The macOS Intel stanza is emitted only when the x86_64-macos tarball is
# present (package-release.sh builds Apple Silicon only by default).

version="${1:?version required, e.g. v0.1.0}"
dist_dir="${2:-dist}"
repo="${SPRTS_TUI_REPO:-h0rv/sprts}"
plain_version="${version#v}"

sha() {
  sha256sum "$dist_dir/$1" | awk '{print $1}'
}

linux_x86="sprts-tui-x86_64-linux.tar.gz"
linux_arm="sprts-tui-aarch64-linux.tar.gz"
mac_arm="sprts-tui-aarch64-macos.tar.gz"
mac_x86="sprts-tui-x86_64-macos.tar.gz"

mac_intel_block=""
if [ -f "$dist_dir/$mac_x86" ]; then
  mac_intel_block="$(cat <<EOF
    on_intel do
      url "https://github.com/$repo/releases/download/$version/$mac_x86"
      sha256 "$(sha "$mac_x86")"
    end

EOF
)"
fi

cat <<EOF
class SprtsTui < Formula
  desc "Live sports scores in your terminal"
  homepage "https://github.com/$repo"
  version "$plain_version"
  license "MIT"

  on_macos do
${mac_intel_block}    on_arm do
      url "https://github.com/$repo/releases/download/$version/$mac_arm"
      sha256 "$(sha "$mac_arm")"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/$repo/releases/download/$version/$linux_x86"
      sha256 "$(sha "$linux_x86")"
    end

    on_arm do
      url "https://github.com/$repo/releases/download/$version/$linux_arm"
      sha256 "$(sha "$linux_arm")"
    end
  end

  def install
    bin.install Dir["sprts-tui*/sprts-tui"].first
  end

  test do
    assert_match "sprts-tui", shell_output("#{bin}/sprts-tui --help")
  end
end
EOF
