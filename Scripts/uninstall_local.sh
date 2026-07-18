#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
purge=false
[[ "${1:-}" == "--purge" ]] && purge=true
[[ $# -le 1 ]] || { print -u2 "usage: $0 [--purge]"; exit 2; }

stopped_pids=()
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

swift "$script_dir/install_hooks.swift" remove

app_path="$HOME/Applications/Cowlick.app"
legacy_app_path="$HOME/Applications/NotchRelay.app"
helper_path="$HOME/Library/Application Support/Cowlick/bin/cowlick-hook"
legacy_helper_path="$HOME/Library/Application Support/NotchRelay/bin/notchrelay-hook"
shim_path="$HOME/.local/bin/cowlick-hook"
legacy_shim_path="$HOME/.local/bin/notchrelay-hook"
runtime_socket="${TMPDIR%/}/Cowlick-$(id -u)/bridge.sock"
legacy_runtime_socket="${TMPDIR%/}/NotchRelay-$(id -u)/bridge.sock"

[[ -L "$shim_path" && "$(readlink "$shim_path")" == "$helper_path" ]] && rm "$shim_path"
[[ -L "$legacy_shim_path" && "$(readlink "$legacy_shim_path")" == "$legacy_helper_path" ]] && rm "$legacy_shim_path"
[[ -f "$helper_path" ]] && rm "$helper_path"
[[ -f "$legacy_helper_path" ]] && rm "$legacy_helper_path"
[[ -d "$app_path" ]] && rm -rf "$app_path"
[[ -d "$legacy_app_path" ]] && rm -rf "$legacy_app_path"
[[ -S "$runtime_socket" ]] && rm "$runtime_socket"
[[ -S "$legacy_runtime_socket" ]] && rm "$legacy_runtime_socket"

if $purge; then
  rm -rf "$HOME/Library/Application Support/Cowlick"
  rm -rf "$HOME/Library/Application Support/NotchRelay"
  defaults delete com.henryvn27.Cowlick 2>/dev/null || true
  defaults delete com.henryvn27.NotchRelay 2>/dev/null || true
  print "Removed Cowlick, its integration, settings, and runtime data."
else
  print "Removed Cowlick and its integration. Preferences and diagnostics were preserved."
fi
