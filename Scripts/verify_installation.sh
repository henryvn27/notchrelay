#!/bin/zsh
set -euo pipefail

app_path=""
development=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app_path="$2"; shift 2 ;;
    --development) development=true; shift ;;
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

if [[ -x "$HOME/.local/bin/cowlick-hook" ]]; then
  diagnostics_file="$(mktemp "${TMPDIR%/}/cowlick-diagnostics.XXXXXX")"
  chmod 600 "$diagnostics_file"
  trap 'rm -f "$diagnostics_file"' EXIT
  "$HOME/.local/bin/cowlick-hook" diagnostics >"$diagnostics_file"
  plutil -lint "$diagnostics_file" >/dev/null 2>&1 || python3 -m json.tool "$diagnostics_file" >/dev/null
  rm -f "$diagnostics_file"
  trap - EXIT
fi

if ! $development; then
  codesign -dv --verbose=4 "$app_path" 2>&1 | grep -q 'flags=.*runtime'
  spctl --assess --type execute --verbose=2 "$app_path"
fi

print "Verified app structure, signature, Info.plist, helper version, and available bridge diagnostics."
