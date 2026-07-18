#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
version="${1:-1.0.0}"
source "$script_dir/release_common.sh"
validate_release_version "$version"
profile="${NOTARYTOOL_PROFILE:-cowlick-notary}"
output="$project_root/build/release-$version"
notary_arguments=(--keychain-profile "$profile")
if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
  notary_arguments+=(--keychain "$NOTARYTOOL_KEYCHAIN")
fi

"$script_dir/release_preflight.sh" "$version" --distribution
"$script_dir/package_release.sh" "$version"
app="$project_root/build/export-$version/Cowlick.app"
zip="$output/Cowlick-$version.zip"
dmg="$output/Cowlick-$version.dmg"

# Notarize the app in a ZIP first so its ticket can be stapled before either
# public container is finalized. The final DMG is then notarized and stapled as
# its own distributable artifact.
xcrun notarytool submit "$zip" "${notary_arguments[@]}" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

rm -f "$zip" "$dmg" "$output/checksums.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
dmg_root="$output/dmg-root-final"
mkdir -p "$dmg_root"
ditto "$app" "$dmg_root/Cowlick.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -volname Cowlick -srcfolder "$dmg_root" -ov -format UDZO "$dmg"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$dmg"
rm -rf "$dmg_root"

xcrun notarytool submit "$dmg" "${notary_arguments[@]}" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$dmg"
(cd "$output" && shasum -a 256 "Cowlick-$version.zip" "Cowlick-$version.dmg" > checksums.txt)
"$script_dir/generate_appcast.sh" "$output" "$version"

print "Signed, notarized, stapled, and appcast-ready artifacts are in $output"
