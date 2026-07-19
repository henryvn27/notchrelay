#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release_common.sh"

version="${1:-}"
shift || true
validate_release_version "$version"

expected=(
  "Cowlick-$version.dmg"
  "Cowlick-$version.zip"
  "appcast.xml"
  "checksums.txt"
)

temporary_directory="$(mktemp -d "${TMPDIR%/}/cowlick-release-assets.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

printf '%s\n' "${expected[@]}" | LC_ALL=C sort > "$temporary_directory/expected"
printf '%s\n' "$@" | LC_ALL=C sort > "$temporary_directory/actual"

if ! cmp -s "$temporary_directory/expected" "$temporary_directory/actual"; then
  print -u2 -- "release error: GitHub release assets do not match the expected set"
  diff -u "$temporary_directory/expected" "$temporary_directory/actual" >&2 || true
  exit 1
fi

print "Cowlick $version GitHub release asset names verified."
