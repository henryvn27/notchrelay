#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_svg="$root_dir/Assets/AppIcon/cowlick-icon.svg"
iconset_dir="$root_dir/Cowlick/Resources/Assets.xcassets/AppIcon.appiconset"

mkdir -p "$iconset_dir"

for size in 16 32 64 128 256 512 1024; do
  /usr/bin/sips -s format png -z "$size" "$size" "$source_svg" --out "$iconset_dir/icon-${size}.png" >/dev/null
done

/usr/bin/sips -s format png -z 1024 1024 "$source_svg" --out "$root_dir/Assets/AppIcon/cowlick-icon-1024.png" >/dev/null
