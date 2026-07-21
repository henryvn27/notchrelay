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
  local versions build_numbers
  versions="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$project_root/project.yml" | sort -u)"
  [[ "$versions" == "$expected" ]] \
    || release_error "project MARKETING_VERSION is '${versions//$'\n'/, }', expected '$expected'"
  build_numbers="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*//p' "$project_root/project.yml" | sort -u)"
  [[ "$build_numbers" =~ '^[1-9][0-9]*$' ]] \
    || release_error "app and helper must share one positive CURRENT_PROJECT_VERSION"
}

validate_app_version() {
  local app="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  [[ "$actual" == "$expected" ]] \
    || release_error "built app version is '$actual', expected '$expected'"
}

verify_code_identity() {
  local signed_path="$1"
  local label="$2"
  local expected_identity="$3"
  local expected_team="$4"
  local requires_runtime="${5:-true}"
  local details

  details="$(codesign -dv --verbose=4 "$signed_path" 2>&1)" \
    || { release_error "$label code-signing details are unavailable"; return 1; }
  print -r -- "$details" | grep -Fq "Authority=$expected_identity" \
    || { release_error "$label is not signed by the expected Developer ID identity"; return 1; }
  print -r -- "$details" | grep -Fq "TeamIdentifier=$expected_team" \
    || { release_error "$label is not signed by Apple team $expected_team"; return 1; }
  if [[ "$requires_runtime" == true ]]; then
    print -r -- "$details" | grep -Eq '^CodeDirectory .*flags=.*runtime' \
      || { release_error "$label does not enable Hardened Runtime"; return 1; }
  fi
}

verify_cowlick_app() {
  local app="$1"
  local version="$2"
  local expected_identity="$3"
  local expected_team="$4"
  local helper="$app/Contents/Helpers/cowlick-hook"
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"
  local sparkle_version="$sparkle/Versions/B"
  local bundle_identifier

  [[ -d "$app" ]] || release_error "Cowlick.app is missing"
  [[ -x "$helper" ]] || release_error "bundled cowlick-hook is missing or not executable"
  [[ -d "$sparkle" ]] || release_error "Sparkle.framework is missing"
  validate_app_version "$app" "$version"
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$app/Contents/Info.plist")"
  [[ "$bundle_identifier" == "com.henryvn27.Cowlick" ]] \
    || release_error "built app bundle identifier is '$bundle_identifier', expected 'com.henryvn27.Cowlick'"

  codesign --verify --deep --strict --verbose=2 "$app"
  codesign --verify --strict --verbose=2 "$helper"
  verify_code_identity "$app" "Cowlick.app" "$expected_identity" "$expected_team"
  verify_code_identity "$helper" "cowlick-hook" "$expected_identity" "$expected_team"
  verify_code_identity "$sparkle" "Sparkle.framework" "$expected_identity" "$expected_team"
  verify_code_identity "$sparkle_version/Updater.app" "Sparkle Updater.app" \
    "$expected_identity" "$expected_team"
  verify_code_identity "$sparkle_version/Autoupdate" "Sparkle Autoupdate" \
    "$expected_identity" "$expected_team"
  verify_code_identity "$sparkle_version/XPCServices/Downloader.xpc" \
    "Sparkle Downloader.xpc" "$expected_identity" "$expected_team"
  verify_code_identity "$sparkle_version/XPCServices/Installer.xpc" \
    "Sparkle Installer.xpc" "$expected_identity" "$expected_team"
  codesign -dv --verbose=4 "$app" 2>&1 | grep -Fq 'Identifier=com.henryvn27.Cowlick' \
    || release_error "Cowlick.app code-signing identifier is incorrect"
  spctl --assess --type execute --verbose=2 "$app"
  lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/Cowlick"
  lipo -verify_arch arm64 x86_64 "$helper"
}

code_directory_hash() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1
}

require_release_command() {
  command -v "$1" >/dev/null 2>&1 || release_error "required command is unavailable: $1"
}
