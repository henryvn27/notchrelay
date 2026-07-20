#!/bin/zsh

cowlick_xcode_build_jobs() {
  local jobs="${COWLICK_XCODE_JOBS:-2}"
  if [[ ! "$jobs" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 -- "COWLICK_XCODE_JOBS must be a positive integer (received: $jobs)."
    return 2
  fi
  print -r -- "$jobs"
}
