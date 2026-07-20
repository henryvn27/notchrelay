#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository="$root_dir"
require_clean=false

usage() {
  echo "Usage: ./Scripts/product_source_digest.sh [--repository PATH] [--require-clean] SOURCE_REF" >&2
}

while (($#)); do
  case "$1" in
    --repository)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      repository="$2"
      shift 2
      ;;
    --require-clean)
      require_clean=true
      shift
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      [[ -z "${source_ref:-}" ]] || { usage; exit 2; }
      source_ref="$1"
      shift
      ;;
  esac
done

[[ -n "${source_ref:-}" ]] || { usage; exit 2; }
source_sha="$(git -C "$repository" rev-parse --verify --end-of-options "${source_ref}^{commit}" 2>/dev/null)" || {
  echo "Product-source digest error: cannot resolve source ref '$source_ref'." >&2
  exit 1
}

# Schema 2 contract. Changing this scope, ordering, or serialization requires a schema bump.
product_source_paths=(Cowlick CowlickHook Config project.yml Package.resolved Cowlick.xcodeproj)
for product_source_path in "${product_source_paths[@]}"; do
  git -C "$repository" cat-file -e "$source_sha:$product_source_path" 2>/dev/null || {
    echo "Product-source digest error: source is missing $product_source_path." >&2
    exit 1
  }
done

if $require_clean; then
  product_status="$(
    git -C "$repository" status --porcelain=v1 --untracked-files=all -- \
      "${product_source_paths[@]}"
  )"
  [[ -z "$product_status" ]] || {
    echo "Product-source digest error: capture scope has staged, unstaged, or untracked changes." >&2
    exit 1
  }
fi

git -C "$repository" ls-tree -r -z --full-tree "$source_sha" -- "${product_source_paths[@]}" \
  | shasum -a 256 | awk '{print $1}'
