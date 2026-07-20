#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path=""
source_ref=""

while (($#)); do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "--app requires a Cowlick.app path" >&2; exit 2; }
      app_path="$2"
      shift 2
      ;;
    --source-ref)
      [[ $# -ge 2 ]] || { echo "--source-ref requires a commit" >&2; exit 2; }
      source_ref="$2"
      shift 2
      ;;
    *)
      echo "Usage: ./Scripts/capture_launch_assets.sh --app /path/to/Cowlick.app --source-ref COMMIT" >&2
      exit 2
      ;;
  esac
done

[[ -n "$app_path" && -n "$source_ref" ]] || {
  echo "Pass the exact Cowlick.app build and source commit being prepared for release." >&2
  exit 2
}
[[ -x "$app_path/Contents/MacOS/Cowlick" ]] || {
  echo "Cowlick executable is missing from $app_path" >&2
  exit 1
}

source_sha="$(git -C "$root_dir" rev-parse --verify --end-of-options "$source_ref^{commit}")" || {
  echo "Could not resolve source ref: $source_ref" >&2
  exit 1
}
head_sha="$(git -C "$root_dir" rev-parse HEAD)"
[[ "$source_sha" == "$head_sha" ]] || {
  echo "Launch assets must be captured from the current checkout HEAD ($head_sha), not $source_sha." >&2
  exit 1
}
embedded_source_file="$app_path/Contents/Resources/cowlick-source-commit.txt"
[[ -f "$embedded_source_file" ]] || {
  echo "Cowlick source identity is missing from $app_path; rebuild the app before capture." >&2
  exit 1
}
embedded_source_sha="$(tr -d '[:space:]' < "$embedded_source_file")"
[[ "$embedded_source_sha" == "$source_sha" ]] || {
  echo "Cowlick.app was built from $embedded_source_sha, not requested source $source_sha; rebuild before capture." >&2
  exit 1
}

xcrun swift "$root_dir/Scripts/capture_launch_assets.swift" --app "$app_path"
xcrun swift "$root_dir/Scripts/generate_demo.swift"
"$root_dir/Scripts/record_launch_asset_provenance.sh" --app "$app_path" --source-ref "$source_sha"
xcrun swift "$root_dir/Scripts/generate_launch_assets.swift"
xcrun swift "$root_dir/Scripts/validate_launch_assets.swift" --source-ref "$source_sha"

echo "Cowlick launch assets captured, generated, and validated from $app_path at $source_sha"
