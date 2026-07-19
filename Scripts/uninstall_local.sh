#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
purge=false

usage() {
  print "usage: $0 [--purge]"
}

case "${1:-}" in
  "") [[ $# == 0 ]] || { usage >&2; exit 2; } ;;
  --purge) [[ $# == 1 ]] || { usage >&2; exit 2; }; purge=true ;;
  -h|--help) [[ $# == 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [[ -z "${COWLICK_LOCAL_LIFECYCLE_LOCK_HELD:-}" ]]; then
  mkdir -p "$HOME/.codex"
  export COWLICK_LOCAL_LIFECYCLE_LOCK_HELD=1
  exec /usr/bin/lockf -k "$HOME/.codex/.cowlick-local-lifecycle.lock" \
    "$script_dir/uninstall_local.sh" "$@"
fi

purge_tool_directory=""
cleanup() {
  [[ -n "$purge_tool_directory" && -d "$purge_tool_directory" ]] \
    && rm -rf "$purge_tool_directory"
}
trap cleanup EXIT

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

if $purge; then
  purge_tool_directory="$(mktemp -d "${TMPDIR%/}/cowlick-credential-purge.XXXXXX")"
  chmod 700 "$purge_tool_directory"
  purge_tool="$purge_tool_directory/purge-provider-credentials"
  xcrun swiftc -parse-as-library \
    "$project_root/Cowlick/Support/ProductIdentity.swift" \
    "$project_root/Cowlick/Support/AppSupportPaths.swift" \
    "$project_root/Cowlick/Models/UsageProvider.swift" \
    "$project_root/Cowlick/Services/CredentialSecretStore.swift" \
    "$project_root/Cowlick/Stores/ProviderAccountStore.swift" \
    "$script_dir/purge_provider_credentials.swift" \
    -o "$purge_tool"
  "$purge_tool" "$HOME/Library/Application Support/Cowlick/provider-accounts.json"
fi

swift "$script_dir/install_hooks.swift" remove

app_path="$HOME/Applications/Cowlick.app"
legacy_app_path="$HOME/Applications/NotchRelay.app"
runtime_socket="${TMPDIR%/}/Cowlick-$(id -u)/bridge.sock"
legacy_runtime_socket="${TMPDIR%/}/NotchRelay-$(id -u)/bridge.sock"

[[ -d "$app_path" ]] && rm -rf "$app_path"
[[ -d "$legacy_app_path" ]] && rm -rf "$legacy_app_path"
[[ -S "$runtime_socket" ]] && rm "$runtime_socket"
[[ -S "$legacy_runtime_socket" ]] && rm "$legacy_runtime_socket"

if $purge; then
  rm -rf "$HOME/Library/Application Support/Cowlick"
  rm -rf "$HOME/Library/Application Support/NotchRelay"
  swift "$script_dir/install_hooks.swift" remove >/dev/null
  defaults delete com.henryvn27.Cowlick 2>/dev/null || true
  defaults delete com.henryvn27.NotchRelay 2>/dev/null || true
  print "Removed Cowlick, its integration, settings, and runtime data."
else
  print "Removed Cowlick and its integration. Preferences and diagnostics were preserved."
fi
