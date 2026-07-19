#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release_common.sh"

(( $# == 3 )) || release_error "stability guard requires state file, observation, and count"
state_file="$1"
observation="$2"
required_count="$3"
[[ "$required_count" == <1-> ]] || release_error "stability count must be positive"

digest="$(print -rn -- "$observation" | shasum -a 256 | awk '{print $1}')"
count=1
if [[ -f "$state_file" ]]; then
  previous="$(<"$state_file")"
  previous_digest="${previous%%$'\t'*}"
  previous_count="${previous#*$'\t'}"
  if [[ "$previous_digest" == "$digest" && "$previous_count" == <1-> ]]; then
    count=$(( previous_count + 1 ))
  fi
fi
printf '%s\t%s\n' "$digest" "$count" > "$state_file"

if (( count >= required_count )); then
  print stable
else
  print pending
fi
