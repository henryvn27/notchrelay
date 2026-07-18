#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "$script_dir/release_common.sh"

version="${1:?usage: render_homebrew_cask.sh VERSION DMG_PATH [OUTPUT]}"
dmg="${2:?usage: render_homebrew_cask.sh VERSION DMG_PATH [OUTPUT]}"
output="${3:-$project_root/Config/Homebrew/cowlick.rb}"
validate_release_version "$version"
[[ -f "$dmg" ]] || { print -u2 "DMG not found: $dmg"; exit 1; }
sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"

temporary="$(mktemp)"
sed -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$sha/g" \
  "$project_root/Config/Homebrew/cowlick.rb.template" > "$temporary"
mv "$temporary" "$output"
ruby -c "$output"
print "$output"
