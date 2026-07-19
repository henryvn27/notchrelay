#!/bin/zsh
set -euo pipefail

release_ref="${1:-HEAD}"
main_ref="${2:-refs/remotes/origin/main}"

release_sha="$(git rev-parse --verify --end-of-options "${release_ref}^{commit}" 2>/dev/null)" \
  || { print -u2 -- "release provenance error: cannot resolve release ref '$release_ref'"; exit 1; }
main_sha="$(git rev-parse --verify --end-of-options "${main_ref}^{commit}" 2>/dev/null)" \
  || { print -u2 -- "release provenance error: cannot resolve main ref '$main_ref'"; exit 1; }

if [[ "$release_sha" != "$main_sha" ]]; then
  print -u2 -- "release provenance error: release commit $release_sha does not match current main $main_sha"
  exit 1
fi

print -r -- "$release_sha"
