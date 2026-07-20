#!/bin/zsh

cowlick_xcode_build_jobs() {
  local jobs="${COWLICK_XCODE_JOBS:-2}"
  if [[ ! "$jobs" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 -- "COWLICK_XCODE_JOBS must be a positive integer (received: $jobs)."
    return 2
  fi
  print -r -- "$jobs"
}

cowlick_host_architecture() {
  local architecture
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
    architecture="arm64"
  else
    architecture="$(uname -m)"
  fi
  case "$architecture" in
    arm64 | x86_64) print -r -- "$architecture" ;;
    *) print -u2 -- "Unsupported Mac architecture: $architecture"; return 2 ;;
  esac
}
