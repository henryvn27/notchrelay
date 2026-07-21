#!/bin/zsh
set -euo pipefail

version="2.46.0"
sha256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
install_root="${RUNNER_TEMP:?RUNNER_TEMP is required}/cowlick-xcodegen-$version"
archive="$install_root/xcodegen.zip"

mkdir -p "$install_root"
curl --fail --silent --show-error --location \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" \
  --output "$archive"
printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 --check --status
unzip -q "$archive" -d "$install_root"

binary_directory="$install_root/xcodegen/bin"
[[ "$("$binary_directory/xcodegen" --version)" == "Version: $version" ]]
printf '%s\n' "$binary_directory" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
