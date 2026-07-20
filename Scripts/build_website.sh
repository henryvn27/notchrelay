#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
source_directory="$repository_root/Website"
output_directory="$repository_root/build/website"

if [[ "$output_directory" != "$repository_root/build/website" ]]; then
  printf 'Refusing unexpected website output path: %s\n' "$output_directory" >&2
  exit 1
fi

rm -rf "$output_directory"
mkdir -p "$output_directory/assets"

for file in index.html styles.css site.js robots.txt sitemap.xml; do
  cp "$source_directory/$file" "$output_directory/$file"
done

asset_sources=(
  "Assets/AppIcon/cowlick-icon.svg"
  "Assets/AppIcon/cowlick-icon-1024.png"
  "Assets/Screenshots/working.png"
  "Assets/Screenshots/approval.png"
  "Assets/Screenshots/completed.png"
  "Assets/Screenshots/multi-session.png"
  "Assets/Screenshots/usage.png"
  "Assets/Social/github-social-preview.png"
)

asset_destinations=(
  "cowlick-icon.svg"
  "cowlick-icon-1024.png"
  "working.png"
  "approval.png"
  "completed.png"
  "multi-session.png"
  "usage.png"
  "github-social-preview.png"
)

for index in "${!asset_sources[@]}"; do
  cp \
    "$repository_root/${asset_sources[$index]}" \
    "$output_directory/assets/${asset_destinations[$index]}"
done

touch "$output_directory/.nojekyll"

if find "$output_directory" -type l -print -quit | grep -q .; then
  printf 'Website output must not contain symbolic links\n' >&2
  exit 1
fi

printf 'Built Cowlick website at %s\n' "$output_directory"
