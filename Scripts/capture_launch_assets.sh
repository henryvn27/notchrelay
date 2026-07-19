#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path=""

while (($#)); do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "--app requires a Cowlick.app path" >&2; exit 2; }
      app_path="$2"
      shift 2
      ;;
    *)
      echo "Usage: ./Scripts/capture_launch_assets.sh --app /path/to/Cowlick.app" >&2
      exit 2
      ;;
  esac
done

[[ -n "$app_path" ]] || {
  echo "Pass the exact Cowlick.app build being prepared for release with --app." >&2
  exit 2
}
[[ -x "$app_path/Contents/MacOS/Cowlick" ]] || {
  echo "Cowlick executable is missing from $app_path" >&2
  exit 1
}

xcrun swift "$root_dir/Scripts/capture_launch_assets.swift" --app "$app_path"
xcrun swift "$root_dir/Scripts/generate_demo.swift"
xcrun swift "$root_dir/Scripts/generate_launch_assets.swift"
xcrun swift "$root_dir/Scripts/validate_launch_assets.swift"

echo "Cowlick launch assets captured, generated, and validated from $app_path"
