#!/bin/zsh

release_error() {
  print -u2 -- "release error: $*"
  return 1
}

validate_release_version() {
  local version="${1:-}"
  print -r -- "$version" | grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || release_error "invalid semantic version: ${version:-<empty>}"
}

validate_project_version() {
  local project_root="$1"
  local expected="$2"
  local versions
  versions="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$project_root/project.yml" | sort -u)"
  [[ "$versions" == "$expected" ]] \
    || release_error "project MARKETING_VERSION is '${versions//$'\n'/, }', expected '$expected'"
}

validate_app_version() {
  local app="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  [[ "$actual" == "$expected" ]] \
    || release_error "built app version is '$actual', expected '$expected'"
}

require_release_command() {
  command -v "$1" >/dev/null 2>&1 || release_error "required command is unavailable: $1"
}
