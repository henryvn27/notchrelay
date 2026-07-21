#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "$script_dir/xcode_build_jobs.sh"
xcode_jobs="$(cowlick_xcode_build_jobs)"

usage() {
  print "usage: $0"
}

case "${1:-}" in
  "") [[ $# == 0 ]] || { usage >&2; exit 2; } ;;
  -h|--help) [[ $# == 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [[ -z "${COWLICK_LOCAL_LIFECYCLE_LOCK_HELD:-}" ]]; then
  mkdir -p "$HOME/.codex"
  export COWLICK_LOCAL_LIFECYCLE_LOCK_HELD=1
  exec /usr/bin/lockf -k "$HOME/.codex/.cowlick-local-lifecycle.lock" \
    "$script_dir/install_local.sh" "$@"
fi
cd "$project_root"
worktree_status="$(git status --porcelain=v1 --untracked-files=all)" || {
  print -u2 "Could not verify the Cowlick source checkout."
  exit 1
}
[[ -z "$worktree_status" ]] || {
  print -u2 "Refusing to install Cowlick from a dirty checkout. Commit or remove local changes first."
  exit 1
}
derived_data="$project_root/DerivedData"
destination="$HOME/Applications/Cowlick.app"
legacy_destination="$HOME/Applications/NotchRelay.app"
backup=""
install_started=false
legacy_present=false
legacy_removed=false
integration_snapshot_available=false
integration_state_uncertain=false
rollback_snapshot_retained=false
rollback_directory="$(mktemp -d "${TMPDIR%/}/cowlick-install-rollback.XXXXXX")"
chmod 700 "$rollback_directory"
rollback_snapshot_marker="$rollback_directory/.cowlick-integration-snapshot-v1"

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

snapshot_marker_is_valid() {
  local marker="$1" mode
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  [[ "$(/usr/bin/stat -f '%u' -- "$marker" 2>/dev/null)" == "$(/usr/bin/id -u)" ]] \
    || return 1
  mode="$(/usr/bin/stat -f '%Lp' -- "$marker" 2>/dev/null)" || return 1
  (( (8#$mode & 8#77) == 0 )) || return 1
  /usr/bin/cmp -s "$marker" <(print -r -- 1)
}

cleanup_installer() {
  $rollback_snapshot_retained || rm -rf "$rollback_directory"
}

rollback_install() {
  local exit_code="$1"
  if [[ "$exit_code" -eq 0 || "$install_started" != true ]]; then
    return "$exit_code"
  fi

  set +e
  local integration_restored=true
  local destination_removed=true
  local app_restored=false
  local app_relaunched=true
  print -u2 "Local installation failed; restoring the previous Cowlick installation."
  rollback_pids=(${(f)"$(pgrep -x Cowlick 2>/dev/null || true)"})
  for process_id in $rollback_pids; do
    process_path="$(ps -p "$process_id" -o command= 2>/dev/null || true)"
    [[ "$process_path" == *"/Cowlick.app/Contents/MacOS/Cowlick"* ]] && kill "$process_id" 2>/dev/null
  done
  if $integration_snapshot_available; then
    local restore_output restore_exit_code
    restore_output="$(
      swift "$script_dir/install_hooks.swift" restore --snapshot "$rollback_directory" 2>&1
    )"
    restore_exit_code=$?
    if (( restore_exit_code != 0 )); then
      integration_restored=false
      rollback_snapshot_retained=true
      [[ -n "$restore_output" ]] && print -u2 -- "$restore_output"
      print -u2 -- "Cowlick integration restoration failed (exit $restore_exit_code)."
    fi
  elif $integration_state_uncertain; then
    integration_restored=false
    rollback_snapshot_retained=true
    print -u2 "Cowlick integration state is uncertain; no valid rollback snapshot is available."
  fi

  if path_exists "$destination"; then
    /bin/rm -rf "$destination" || destination_removed=false
    if path_exists "$destination"; then
      destination_removed=false
    fi
    if ! $destination_removed; then
      rollback_snapshot_retained=true
      print -u2 -- "Failed Cowlick app could not be removed from $destination"
    fi
  fi

  if [[ -n "$backup" ]]; then
    if path_exists "$backup"; then
      local move_exit_code=0
      if $destination_removed && [[ -d "$backup" && ! -L "$backup" ]]; then
        /bin/mv "$backup" "$destination" || move_exit_code=$?
      elif $destination_removed; then
        move_exit_code=77
      else
        move_exit_code=76
      fi
      if (( move_exit_code == 0 )) && [[ -d "$destination" && ! -L "$destination" ]] \
        && ! path_exists "$backup"; then
        app_restored=true
        if ! open -n "$destination" >/dev/null 2>&1; then
          app_relaunched=false
          rollback_snapshot_retained=true
          print -u2 -- "Previous Cowlick app was restored on disk but could not be relaunched from $destination"
        fi
      else
        rollback_snapshot_retained=true
        print -u2 -- "Previous Cowlick app restoration failed (exit $move_exit_code)."
        path_exists "$backup" && print -u2 -- "Previous Cowlick app backup retained at $backup"
      fi
    else
      rollback_snapshot_retained=true
      print -u2 -- "Previous Cowlick app backup is missing from $backup"
    fi
    if $app_restored && $app_relaunched && $integration_restored; then
      print -u2 "Previous local Cowlick app restored."
    elif $app_restored && $app_relaunched; then
      print -u2 "Previous local Cowlick app restored; integration restoration failed."
    fi
  else
    app_restored=$destination_removed
    if $app_restored && $integration_restored; then
      print -u2 "Partial Cowlick installation removed."
    elif $app_restored; then
      print -u2 "Partial Cowlick app installation removed; integration restoration failed."
    else
      rollback_snapshot_retained=true
      print -u2 -- "Partial Cowlick app installation remains at $destination"
    fi
  fi
  if $legacy_present && [[ -d "$legacy_destination" ]]; then
    if ! open -n "$legacy_destination" >/dev/null 2>&1; then
      rollback_snapshot_retained=true
      print -u2 -- "Legacy NotchRelay app could not be relaunched from $legacy_destination"
    fi
  fi
  if $rollback_snapshot_retained; then
    if snapshot_marker_is_valid "$rollback_snapshot_marker"; then
      print -u2 -- "Rollback snapshot retained at $rollback_directory"
    else
      print -u2 -- "Rollback workspace retained at $rollback_directory"
    fi
  fi
  return "$exit_code"
}

trap 'exit_code=$?; rollback_install $exit_code; cleanup_installer; exit $exit_code' EXIT

command -v xcodegen >/dev/null 2>&1 || { print -u2 "Install XcodeGen first: brew install xcodegen"; exit 1; }
cowlick_build_architecture="$(cowlick_host_architecture)"
xcodegen generate
xcodebuild \
  -project Cowlick.xcodeproj \
  -scheme Cowlick \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -destination "platform=macOS,arch=$cowlick_build_architecture" \
  -jobs "$xcode_jobs" \
  ARCHS="$cowlick_build_architecture" \
  ONLY_ACTIVE_ARCH=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  build

source_app="$derived_data/Build/Products/Release/Cowlick.app"
[[ -d "$source_app" ]] || { print -u2 "Release app was not produced"; exit 1; }
source_identity="$source_app/Contents/Resources/cowlick-source-commit.txt"
[[ -f "$source_identity" && ! -L "$source_identity" ]] || {
  print -u2 "Release app is missing its embedded source identity"
  exit 1
}
source_commit="$(tr -d '[:space:]' < "$source_identity")"
[[ "$source_commit" =~ '^[0-9a-f]{40}$' ]] || {
  print -u2 "Release app has an invalid embedded source identity"
  exit 1
}

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
if path_exists "$destination"; then
  backup="$HOME/Applications/Cowlick.app.backup-$(date +%Y%m%d-%H%M%S)"
  mv "$destination" "$backup"
  print "Previous local app moved to $backup"
fi
install_started=true
ditto "$source_app" "$destination"

integration_install_status=0
swift "$script_dir/install_hooks.swift" install \
  --helper "$destination/Contents/Helpers/cowlick-hook" \
  --snapshot "$rollback_directory" || integration_install_status=$?
if snapshot_marker_is_valid "$rollback_snapshot_marker"; then
  integration_snapshot_available=true
elif path_exists "$rollback_snapshot_marker"; then
  integration_state_uncertain=true
  rollback_snapshot_retained=true
fi
if (( integration_install_status != 0 )); then
  exit "$integration_install_status"
fi
if ! $integration_snapshot_available; then
  integration_state_uncertain=true
  rollback_snapshot_retained=true
  print -u2 "Cowlick integration install did not produce a valid rollback snapshot."
  exit 1
fi
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
"$script_dir/verify_installation.sh" --app "$destination" --development --installed \
  --source-commit "$source_commit" \
  --expected-executable "$destination/Contents/MacOS/Cowlick"
if $legacy_present && [[ -d "$legacy_destination" ]]; then
  /bin/rm -rf "$legacy_destination"
  legacy_removed=true
fi
install_started=false
$legacy_removed && print "Removed the replaced NotchRelay development app."
if [[ -n "$backup" && "$backup" == "$HOME/Applications/Cowlick.app.backup-"* ]]; then
  /bin/rm -rf "$backup" || print -u2 "Could not remove the previous Cowlick app backup at $backup"
fi

print "Installed Cowlick locally at $destination"
print "Open Codex /hooks once to review and trust the Cowlick commands if prompted."
