#!/bin/bash
set -euo pipefail

(( $# > 0 )) || {
  printf 'release mutation runner requires a command\n' >&2
  exit 1
}

timeout_seconds="${RELEASE_MUTATION_TIMEOUT_SECONDS:-10}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  printf 'release mutation timeout must be a positive integer\n' >&2
  exit 1
}

export GH_PROMPT_DISABLED=1
trap '' HUP INT TERM
"$@" &
mutation_pid=$!
/usr/bin/perl -e 'sleep shift; kill 9, shift' \
  "$timeout_seconds" "$mutation_pid" &
watchdog_pid=$!

status=0
wait "$mutation_pid" || status=$?
kill -KILL "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" >/dev/null 2>&1 || true
exit "$status"
