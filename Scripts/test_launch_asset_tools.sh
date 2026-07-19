#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

xcrun swift "$root_dir/Scripts/capture_launch_assets.swift" --self-check
xcrun swift "$root_dir/Scripts/validate_launch_assets.swift" --self-check

app="$temporary_directory/Cowlick.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
printf 'app executable' > "$app/Contents/MacOS/Cowlick"
printf 'helper executable' > "$app/Contents/Helpers/cowlick-hook"
chmod +x "$app/Contents/MacOS/Cowlick" "$app/Contents/Helpers/cowlick-hook"
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.henryvn27.Cowlick "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0.0 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"

provenance="$temporary_directory/capture-provenance.json"
"$root_dir/Scripts/record_launch_asset_provenance.sh" \
  --app "$app" --source-ref HEAD --output "$provenance" >/dev/null
grep -Fq "\"sourceCommit\": \"$(git -C "$root_dir" rev-parse HEAD)\"" "$provenance"
grep -Fq '"bundleIdentifier": "com.henryvn27.Cowlick"' "$provenance"
grep -Fq '"marketingVersion": "1.0.0"' "$provenance"
grep -Fq '"buildVersion": "1"' "$provenance"
grep -Eq '"appExecutableSHA256": "[0-9a-f]{64}"' "$provenance"
grep -Eq '"helperExecutableSHA256": "[0-9a-f]{64}"' "$provenance"

if "$root_dir/Scripts/record_launch_asset_provenance.sh" \
  --app "$app" --source-ref does-not-exist --output "$provenance" >/dev/null 2>&1
then
  echo "Unknown provenance source ref was accepted." >&2
  exit 1
fi
