#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
app_path=""
development=false
installed=false
expected_source_commit=""
expected_executable=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app_path="$2"; shift 2 ;;
    --development) development=true; shift ;;
    --installed) installed=true; shift ;;
    --source-commit) expected_source_commit="$2"; shift 2 ;;
    --expected-executable) expected_executable="$2"; shift 2 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
done
[[ -n "$app_path" ]] || app_path="$HOME/Applications/Cowlick.app"

helper="$app_path/Contents/Helpers/cowlick-hook"
[[ -d "$app_path" ]] || { print -u2 "Missing app: $app_path"; exit 1; }
[[ -x "$helper" ]] || { print -u2 "Missing bundled helper: $helper"; exit 1; }
plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app_path"
"$helper" version | grep -q '^Cowlick hook 1\.0\.0$'

if [[ -n "$expected_source_commit" ]]; then
  embedded_source_file="$app_path/Contents/Resources/cowlick-source-commit.txt"
  [[ -f "$embedded_source_file" && ! -L "$embedded_source_file" ]] || {
    print -u2 "Missing or unsafe embedded source identity."
    exit 1
  }
  embedded_source_commit="$(tr -d '[:space:]' < "$embedded_source_file")"
  [[ "$embedded_source_commit" =~ '^[0-9a-f]{40}$' ]] || {
    print -u2 "Embedded Cowlick source identity is invalid."
    exit 1
  }
  [[ "$embedded_source_commit" == "$expected_source_commit" ]] || {
    print -u2 "Installed Cowlick source identity does not match the verified commit."
    exit 1
  }
fi

if [[ -x "$helper" ]]; then
  diagnostics_file="$(mktemp "${TMPDIR%/}/cowlick-diagnostics.XXXXXX")"
  diagnostics_plist="${diagnostics_file}.plist"
  chmod 600 "$diagnostics_file"
  trap 'rm -f "$diagnostics_file" "$diagnostics_plist"' EXIT
  if ! "$helper" ping >"$diagnostics_file"; then
    print -u2 "Installed Cowlick helper could not reach a healthy bridge."
    exit 1
  fi
  plutil -convert xml1 -o "$diagnostics_plist" "$diagnostics_file" >/dev/null
  chmod 600 "$diagnostics_plist"
  bridge_ok="$(plutil -extract ok raw -o - "$diagnostics_plist" 2>/dev/null || true)"
  [[ "$bridge_ok" == "true" ]] || {
    print -u2 "Installed Cowlick helper reported an unhealthy bridge."
    exit 1
  }
  bridge_source="$(plutil -extract sourceCommit raw -o - "$diagnostics_plist" 2>/dev/null || true)"
  bridge_pid="$(plutil -extract pid raw -o - "$diagnostics_plist" 2>/dev/null || true)"
  if [[ -n "$expected_source_commit" && "$bridge_source" != "$expected_source_commit" ]]; then
    print -u2 "Healthy bridge belongs to a different Cowlick source commit."
    exit 1
  fi
  if [[ -n "$expected_executable" ]]; then
    [[ "$bridge_pid" =~ '^[1-9][0-9]*$' ]] || {
      print -u2 "Healthy bridge did not report a valid process identifier."
      exit 1
    }
    bridge_command="$(ps -p "$bridge_pid" -o command= 2>/dev/null || true)"
    [[ "$bridge_command" == "$expected_executable"* ]] || {
      print -u2 "Healthy bridge belongs to a different Cowlick executable."
      exit 1
    }
  fi
  rm -f "$diagnostics_file" "$diagnostics_plist"
  trap - EXIT
fi

if $installed; then
  installed_helper="$HOME/Library/Application Support/Cowlick/bin/cowlick-hook"
  shim="$HOME/.local/bin/cowlick-hook"
  [[ -x "$installed_helper" && -L "$shim" ]] || {
    print -u2 "Cowlick's stable helper installation is incomplete."
    exit 1
  }
  [[ "$(readlink "$shim")" == "$installed_helper" ]] || {
    print -u2 "Cowlick's stable helper shim targets an unexpected path."
    exit 1
  }
  cmp -s "$helper" "$installed_helper" || {
    print -u2 "Installed helper does not match the app's bundled helper."
    exit 1
  }
  hook_status="$(COWLICK_HOME="$HOME" swift "$script_dir/install_hooks.swift" status)"
  [[ "$hook_status" == "healthy" ]] || {
    print -u2 "Codex hook integration is unhealthy: $hook_status"
    exit 1
  }
fi

if ! $development; then
  codesign -dv --verbose=4 "$app_path" 2>&1 | grep -q 'flags=.*runtime'
  spctl --assess --type execute --verbose=2 "$app_path"
fi

print "Verified app structure, signature, Info.plist, helper version, and a healthy bridge."
