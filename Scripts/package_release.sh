#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
version="${1:-1.0.0}"
source "$script_dir/release_common.sh"
validate_release_version "$version"
validate_project_version "$project_root" "$version"
identity="${DEVELOPER_ID_APPLICATION:-}"
[[ -n "$identity" ]] || { print -u2 "Set DEVELOPER_ID_APPLICATION to a Developer ID Application identity."; exit 1; }

cd "$project_root"
xcodegen generate
archive="$project_root/build/Cowlick.xcarchive"
output="$project_root/build/release-$version"
export_dir="$project_root/build/export-$version"
rm -rf "$archive" "$output" "$export_dir"
mkdir -p "$output"

xcodebuild archive \
  -project Cowlick.xcodeproj \
  -scheme Cowlick \
  -configuration Release \
  -archivePath "$archive" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$identity" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  OTHER_CODE_SIGN_FLAGS='--timestamp'

# Exporting is a required part of Sparkle's Developer ID signing flow. Xcode's
# export step re-signs Sparkle's nested XPC services and updater helpers with
# the product's identity; packaging the raw archive can leave those components
# with their development signatures and fail Library Validation.
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$project_root/Config/ExportOptions.plist"

app="$export_dir/Cowlick.app"
[[ -d "$app" ]] || { print -u2 "Developer ID export did not produce Cowlick.app."; exit 1; }
validate_app_version "$app" "$version"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -q 'flags=.*runtime'
codesign -dv --verbose=4 "$app" 2>&1 | grep -q 'Authority=Developer ID Application:'
[[ "$(lipo -archs "$app/Contents/MacOS/Cowlick")" == *arm64* ]]
[[ "$(lipo -archs "$app/Contents/MacOS/Cowlick")" == *x86_64* ]]
[[ "$(lipo -archs "$app/Contents/Helpers/cowlick-hook")" == *arm64* ]]
[[ "$(lipo -archs "$app/Contents/Helpers/cowlick-hook")" == *x86_64* ]]

zip="$output/Cowlick-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

dmg_root="$output/dmg-root"
mkdir -p "$dmg_root"
ditto "$app" "$dmg_root/Cowlick.app"
ln -s /Applications "$dmg_root/Applications"
dmg="$output/Cowlick-$version.dmg"
hdiutil create -volname Cowlick -srcfolder "$dmg_root" -ov -format UDZO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
rm -rf "$dmg_root"

for artifact in "$zip" "$dmg"; do
  shasum -a 256 "$artifact" >> "$output/checksums.txt"
done
print "$output"
