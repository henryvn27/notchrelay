#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release_common.sh"

version="${1:-}"
artifact_directory="${2:-}"
validate_release_version "$version"
[[ -d "$artifact_directory" ]] || release_error "artifact directory is missing"

zip="$artifact_directory/Cowlick-$version.zip"
dmg="$artifact_directory/Cowlick-$version.dmg"
checksums="$artifact_directory/checksums.txt"
appcast="$artifact_directory/appcast.xml"
for artifact in "$zip" "$dmg" "$checksums" "$appcast"; do
  [[ -f "$artifact" ]] || release_error "release artifact is missing: ${artifact:t}"
done

for filename in "${zip:t}" "${dmg:t}"; do
  expected="$(awk -v filename="$filename" '$2 == filename { print $1 }' "$checksums")"
  [[ "$expected" =~ '^[0-9a-f]{64}$' ]] \
    || release_error "checksums.txt has no valid SHA-256 for $filename"
  actual="$(shasum -a 256 "$artifact_directory/$filename" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] || release_error "SHA-256 mismatch for $filename"
done
[[ "$(wc -l < "$checksums" | tr -d ' ')" == 2 ]] \
  || release_error "checksums.txt must contain exactly the ZIP and DMG"

xmllint --noout "$appcast"
hdiutil verify "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

unpacked="$(mktemp -d "${TMPDIR%/}/cowlick-release-verify.XXXXXX")"
trap 'rm -rf "$unpacked"' EXIT
ditto -x -k "$zip" "$unpacked"
app="$unpacked/Cowlick.app"
[[ -d "$app" ]] || release_error "release ZIP does not contain Cowlick.app"
validate_app_version "$app" "$version"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/Cowlick"
lipo -verify_arch arm64 x86_64 "$app/Contents/Helpers/cowlick-hook"

print "Cowlick $version release artifacts verified."
