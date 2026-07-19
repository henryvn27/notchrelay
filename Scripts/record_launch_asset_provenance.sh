#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path=""
source_ref=""
output_path="$root_dir/Assets/capture-provenance.json"

usage() {
  echo "Usage: ./Scripts/record_launch_asset_provenance.sh --app /path/to/Cowlick.app --source-ref COMMIT [--output PATH]" >&2
}

while (($#)); do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      app_path="$2"
      shift 2
      ;;
    --source-ref)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      source_ref="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output_path="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$app_path" && -n "$source_ref" ]] || { usage; exit 2; }

source_sha="$(git -C "$root_dir" rev-parse --verify --end-of-options "${source_ref}^{commit}" 2>/dev/null)" || {
  echo "Launch-asset provenance error: cannot resolve source ref '$source_ref'." >&2
  exit 1
}
if ! git -C "$root_dir" merge-base --is-ancestor "$source_sha" HEAD; then
  echo "Launch-asset provenance error: source commit $source_sha is not contained in the capture branch." >&2
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
app_executable="$app_path/Contents/MacOS/Cowlick"
helper_executable="$app_path/Contents/Helpers/cowlick-hook"
for path in "$info_plist" "$app_executable" "$helper_executable"; do
  [[ -f "$path" ]] || { echo "Launch-asset provenance error: missing $path" >&2; exit 1; }
done

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
[[ "$bundle_identifier" == "com.henryvn27.Cowlick" ]] || {
  echo "Launch-asset provenance error: unexpected bundle identifier '$bundle_identifier'." >&2
  exit 1
}
for value in "$marketing_version" "$build_version"; do
  [[ "$value" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    echo "Launch-asset provenance error: unsafe bundle version '$value'." >&2
    exit 1
  }
done

app_sha256="$(shasum -a 256 "$app_executable" | awk '{print $1}')"
helper_sha256="$(shasum -a 256 "$helper_executable" | awk '{print $1}')"
mkdir -p "$(dirname "$output_path")"
temporary_path="$(mktemp "${output_path}.XXXXXX")"
trap 'rm -f "$temporary_path"' EXIT
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  "  \"sourceCommit\": \"$source_sha\"," \
  "  \"bundleIdentifier\": \"$bundle_identifier\"," \
  "  \"marketingVersion\": \"$marketing_version\"," \
  "  \"buildVersion\": \"$build_version\"," \
  "  \"appExecutableSHA256\": \"$app_sha256\"," \
  "  \"helperExecutableSHA256\": \"$helper_sha256\"" \
  '}' > "$temporary_path"
mv "$temporary_path" "$output_path"
trap - EXIT

echo "Recorded launch-asset provenance for Cowlick $marketing_version ($build_version) at $source_sha."
