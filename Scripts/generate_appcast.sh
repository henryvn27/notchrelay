#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
artifact_directory="${1:-$project_root/build/releases}"
version="${2:-1.0.0}"
tool="${SPARKLE_GENERATE_APPCAST:-$project_root/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
[[ -x "$tool" ]] || { print -u2 "Sparkle generate_appcast tool not found. Resolve packages first."; exit 1; }
sign_tool="${tool:h}/sign_update"
[[ -x "$sign_tool" ]] || { print -u2 "Sparkle sign_update tool not found beside generate_appcast."; exit 1; }
archive="$artifact_directory/NotchRelay-$version.zip"
[[ -f "$archive" ]] || { print -u2 "Sparkle update ZIP not found: $archive"; exit 1; }
staging_directory="$(mktemp -d "${TMPDIR%/}/notchrelay-appcast.XXXXXX")"
chmod 700 "$staging_directory"
trap 'rm -rf "$staging_directory"' EXIT
cp "$archive" "$staging_directory/NotchRelay-$version.zip"
cp "$project_root/CHANGELOG.md" "$staging_directory/NotchRelay-$version.md"

arguments=(
  --download-url-prefix "https://github.com/henryvn27/notchrelay/releases/download/v$version/"
  --link "https://github.com/henryvn27/notchrelay"
  --embed-release-notes
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -r -- "$SPARKLE_PRIVATE_KEY" | "$tool" "${arguments[@]}" --ed-key-file - "$staging_directory"
else
  "$tool" "${arguments[@]}" --account notchrelay "$staging_directory"
fi
appcast="$staging_directory/appcast.xml"
[[ -f "$appcast" ]] || { print -u2 "Appcast was not generated"; exit 1; }
rg -q 'sparkle:edSignature=' "$appcast" || { print -u2 "Update archive signature is missing"; exit 1; }
rg -q '<!-- sparkle-signatures:' "$appcast" || { print -u2 "Signed-feed signature block is missing"; exit 1; }
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -r -- "$SPARKLE_PRIVATE_KEY" | "$sign_tool" --verify --ed-key-file - "$appcast"
else
  "$sign_tool" --account notchrelay --verify "$appcast"
fi
mv "$appcast" "$artifact_directory/appcast.xml"
print "Generated signed appcast.xml"
