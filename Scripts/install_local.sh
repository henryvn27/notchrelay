#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
derived_data="$project_root/DerivedData"
destination="$HOME/Applications/Cowlick.app"
legacy_destination="$HOME/Applications/NotchRelay.app"
backup=""
install_started=false
legacy_present=false
hooks_updated=false
hooks_existed=false
hooks_path="$HOME/.codex/hooks.json"
rollback_directory="$(mktemp -d "${TMPDIR%/}/cowlick-install-rollback.XXXXXX")"
chmod 700 "$rollback_directory"

cleanup_installer() {
  rm -rf "$rollback_directory"
}

rollback_install() {
  local exit_code="$1"
  if [[ "$exit_code" -eq 0 || "$install_started" != true ]]; then
    return "$exit_code"
  fi

  set +e
  print -u2 "Local installation failed; restoring the previous Cowlick installation."
  rollback_pids=(${(f)"$(pgrep -x Cowlick 2>/dev/null || true)"})
  for process_id in $rollback_pids; do
    process_path="$(ps -p "$process_id" -o command= 2>/dev/null || true)"
    [[ "$process_path" == *"/Cowlick.app/Contents/MacOS/Cowlick"* ]] && kill "$process_id" 2>/dev/null
  done
  if $hooks_updated; then
    if $hooks_existed; then
      hooks_restore="$HOME/.codex/.hooks.json.cowlick-rollback"
      ditto "$rollback_directory/hooks.json" "$hooks_restore"
      chmod 600 "$hooks_restore"
      mv "$hooks_restore" "$hooks_path"
    else
      swift "$script_dir/install_hooks.swift" remove >/dev/null 2>&1
    fi
  fi
  [[ -d "$destination" ]] && /bin/rm -rf "$destination"
  if [[ -n "$backup" && -d "$backup" ]]; then
    mv "$backup" "$destination"
    open -n "$destination" >/dev/null 2>&1
    print -u2 "Previous local Cowlick app restored."
  else
    swift "$script_dir/install_hooks.swift" remove >/dev/null 2>&1
    helper_path="$HOME/Library/Application Support/Cowlick/bin/cowlick-hook"
    shim_path="$HOME/.local/bin/cowlick-hook"
    [[ -L "$shim_path" && "$(readlink "$shim_path")" == "$helper_path" ]] && rm "$shim_path"
    [[ -f "$helper_path" ]] && rm "$helper_path"
    print -u2 "Partial Cowlick installation removed."
  fi
  if $legacy_present && [[ -d "$legacy_destination" ]]; then
    open -n "$legacy_destination" >/dev/null 2>&1
  fi
  return "$exit_code"
}

trap 'exit_code=$?; rollback_install $exit_code; cleanup_installer; exit $exit_code' EXIT

cd "$project_root"
command -v xcodegen >/dev/null 2>&1 || { print -u2 "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate
xcodebuild \
  -project Cowlick.xcodeproj \
  -scheme Cowlick \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -destination 'platform=macOS,arch=arm64' \
  ENABLE_HARDENED_RUNTIME=NO \
  build

source_app="$derived_data/Build/Products/Release/Cowlick.app"
[[ -d "$source_app" ]] || { print -u2 "Release app was not produced"; exit 1; }

stopped_pids=()
[[ -d "$legacy_destination" ]] && legacy_present=true
for process_name in Cowlick NotchRelay; do
  existing_pids=(${(f)"$(pgrep -x "$process_name" 2>/dev/null || true)"})
  for process_id in $existing_pids; do
    process_path="$(ps -p "$process_id" -o command= 2>/dev/null || true)"
    if [[ "$process_path" == *"/$process_name.app/Contents/MacOS/$process_name"* ]]; then
      kill "$process_id"
      stopped_pids+=("$process_id")
    fi
  done
done
for process_id in $stopped_pids; do
  for _ in {1..50}; do
    kill -0 "$process_id" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$process_id" 2>/dev/null && {
    print -u2 "App process $process_id did not stop cleanly."
    exit 1
  }
done

mkdir -p "$HOME/Applications"
if [[ -d "$destination" ]]; then
  backup="$HOME/Applications/Cowlick.app.backup-$(date +%Y%m%d-%H%M%S)"
  mv "$destination" "$backup"
  print "Previous local app moved to $backup"
fi
install_started=true
ditto "$source_app" "$destination"

if [[ -f "$hooks_path" ]]; then
  hooks_existed=true
  ditto "$hooks_path" "$rollback_directory/hooks.json"
  chmod 600 "$rollback_directory/hooks.json"
fi
swift "$script_dir/install_hooks.swift" install --helper "$destination/Contents/Helpers/cowlick-hook"
hooks_updated=true
open -n "$destination"
bridge_ready=false
for _ in {1..20}; do
  if "$HOME/.local/bin/cowlick-hook" ping >/dev/null 2>&1; then
    bridge_ready=true
    break
  fi
  sleep 0.25
done
$bridge_ready || { print -u2 "Installed app did not start its authenticated bridge."; exit 1; }
"$script_dir/verify_installation.sh" --app "$destination" --development
if [[ -n "$backup" && "$backup" == "$HOME/Applications/Cowlick.app.backup-"* ]]; then
  /bin/rm -rf "$backup"
fi
if $legacy_present && [[ -d "$legacy_destination" ]]; then
  /bin/rm -rf "$legacy_destination"
  print "Removed the replaced NotchRelay development app."
fi
install_started=false

print "Installed Cowlick locally at $destination"
print "Open Codex /hooks once to review and trust the four Cowlick commands if prompted."
