#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release_common.sh"

(( $# == 10 )) || release_error "tap rollback guard requires ten arguments"
prior_state="$1"
prior_sha="$2"
prior_file="$3"
current_state="$4"
current_sha="$5"
current_file="$6"
published_content_sha="$7"
latest_commit_sha="$8"
published_commit_sha="$9"
desired_file="${10}"

[[ "$prior_state" == present || "$prior_state" == absent ]] \
  || release_error "tap rollback prior state is invalid"
[[ "$current_state" == present || "$current_state" == absent ]] \
  || release_error "tap rollback current state is invalid"

if [[ "$prior_state" == present \
  && "$current_state" == present \
  && -n "$prior_sha" \
  && "$current_sha" == "$prior_sha" \
  && -f "$prior_file" \
  && -f "$current_file" ]] \
  && cmp -s "$prior_file" "$current_file"; then
  print restored
  exit 0
fi

if [[ "$prior_state" == absent && "$current_state" == absent ]]; then
  print restored
  exit 0
fi

if [[ "$current_state" == present \
  && -n "$published_content_sha" \
  && -n "$published_commit_sha" \
  && "$current_sha" == "$published_content_sha" \
  && "$latest_commit_sha" == "$published_commit_sha" \
  && -f "$current_file" \
  && -f "$desired_file" ]] \
  && cmp -s "$desired_file" "$current_file"; then
  print owned
  exit 0
fi

release_error "Homebrew tap no longer matches this run publication; refusing to overwrite it"
