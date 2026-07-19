#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "$script_dir/release_common.sh"

temporary_directory="$(mktemp -d "${TMPDIR%/}/cowlick-release-tests.XXXXXX")"
chmod 700 "$temporary_directory"
trap 'rm -rf "$temporary_directory"' EXIT

"$script_dir/release_preflight.sh" 1.0.0 --source-only >/dev/null
grep -Fq 'requires_signed_feed' "$script_dir/release_preflight.sh"
grep -Fq 'export method must be developer-id' "$script_dir/release_preflight.sh"
grep -Fq 'CHANGELOG.md has no release section' "$script_dir/release_preflight.sh"

release_notes="$temporary_directory/release-notes.md"
"$script_dir/release_notes.sh" 1.0.0 > "$release_notes"
grep -Eq '^## 1\.0\.0$' "$release_notes"
[[ "$(grep -c '^## ' "$release_notes")" == 1 ]]
if grep -Fq '## Unreleased' "$release_notes"; then
  print -u2 -- "version-scoped release notes included the Unreleased section"
  exit 1
fi
if "$script_dir/release_notes.sh" 9.9.9 >/dev/null 2>&1; then
  print -u2 -- "missing release-notes section unexpectedly passed"
  exit 1
fi

expected_release_assets=(
  Cowlick-1.0.0.dmg
  Cowlick-1.0.0.zip
  appcast.xml
  checksums.txt
)
"$script_dir/release_verify_asset_names.sh" 1.0.0 \
  "${expected_release_assets[@]}" >/dev/null
asset_failure="$temporary_directory/asset-failure.txt"
if "$script_dir/release_verify_asset_names.sh" 1.0.0 \
  "${expected_release_assets[@]}" unexpected.txt >"$asset_failure" 2>&1; then
  print -u2 -- "unexpected GitHub release asset set passed"
  exit 1
fi
grep -Fq 'GitHub release assets do not match the expected set' "$asset_failure"
if "$script_dir/release_verify_asset_names.sh" 1.0.0 \
  Cowlick-1.0.0.dmg Cowlick-1.0.0.zip appcast.xml >/dev/null 2>&1; then
  print -u2 -- "incomplete GitHub release asset set passed"
  exit 1
fi
if "$script_dir/release_verify_asset_names.sh" 1.0.0 \
  "${expected_release_assets[@]}" appcast.xml >/dev/null 2>&1; then
  print -u2 -- "duplicate GitHub release asset set passed"
  exit 1
fi

tap_fixture="$temporary_directory/tap-rollback"
mkdir -p "$tap_fixture"
print -n -- 'prior cask' > "$tap_fixture/prior.rb"
print -n -- 'published cask' > "$tap_fixture/published.rb"
print -n -- 'published cask' > "$tap_fixture/desired.rb"
[[ "$("$script_dir/release_tap_rollback_guard.sh" \
  present prior-content "$tap_fixture/prior.rb" \
  present prior-content "$tap_fixture/prior.rb" \
  published-content published-commit published-commit "$tap_fixture/desired.rb")" == restored ]]
[[ "$("$script_dir/release_tap_rollback_guard.sh" \
  present prior-content "$tap_fixture/prior.rb" \
  present published-content "$tap_fixture/published.rb" \
  published-content published-commit published-commit "$tap_fixture/desired.rb")" == owned ]]
[[ "$("$script_dir/release_tap_rollback_guard.sh" \
  absent '' "$tap_fixture/missing-prior.rb" \
  absent '' "$tap_fixture/missing-current.rb" \
  published-content published-commit published-commit "$tap_fixture/desired.rb")" == restored ]]
for rejected_guard in \
  "present prior-content $tap_fixture/prior.rb absent '' $tap_fixture/missing-current.rb published-content published-commit published-commit $tap_fixture/desired.rb" \
  "present prior-content $tap_fixture/prior.rb present published-content $tap_fixture/published.rb published-content concurrent-commit published-commit $tap_fixture/desired.rb" \
  "present prior-content $tap_fixture/prior.rb present concurrent-content $tap_fixture/published.rb published-content published-commit published-commit $tap_fixture/desired.rb" \
  "present prior-content $tap_fixture/prior.rb present published-content $tap_fixture/prior.rb published-content published-commit published-commit $tap_fixture/desired.rb" \
  "absent '' $tap_fixture/missing-prior.rb present concurrent-content $tap_fixture/published.rb published-content published-commit published-commit $tap_fixture/desired.rb"; do
  if "$script_dir/release_tap_rollback_guard.sh" ${(z)rejected_guard} >/dev/null 2>&1; then
    print -u2 -- "tap rollback accepted state not owned by this release: $rejected_guard"
    exit 1
  fi
done

[[ "$("$script_dir/release_run_mutation.sh" /bin/sh -c \
  'kill -TERM $$; printf mutation-survived')" == mutation-survived ]]
if RELEASE_MUTATION_TIMEOUT_SECONDS=1 "$script_dir/release_run_mutation.sh" \
  /bin/sh -c 'sleep 5' >/dev/null 2>&1; then
  print -u2 -- "release mutation runner did not enforce its deadline"
  exit 1
fi

delayed_stability="$temporary_directory/delayed-mutation-stability"
initial_rollback_state="$("$script_dir/release_tap_rollback_guard.sh" \
  present prior-content "$tap_fixture/prior.rb" \
  present prior-content "$tap_fixture/prior.rb" \
  published-content published-commit published-commit "$tap_fixture/desired.rb")"
[[ "$("$script_dir/release_stability_guard.sh" \
  "$delayed_stability" "$initial_rollback_state:prior-object:prior-commit" 4)" == pending ]]
delayed_rollback_state="$("$script_dir/release_tap_rollback_guard.sh" \
  present prior-content "$tap_fixture/prior.rb" \
  present published-content "$tap_fixture/published.rb" \
  published-content published-commit published-commit "$tap_fixture/desired.rb")"
[[ "$("$script_dir/release_stability_guard.sh" \
  "$delayed_stability" "$delayed_rollback_state:published-object:cowlick-run-marker" 4)" == pending ]]
for expected_state in pending pending pending stable; do
  actual_state="$("$script_dir/release_stability_guard.sh" \
    "$delayed_stability" "$initial_rollback_state:prior-object:rollback-commit" 4)"
  [[ "$actual_state" == "$expected_state" ]] || {
    print -u2 -- "delayed mutation was accepted before rollback restabilized"
    exit 1
  }
done

fake_bin="$temporary_directory/fake-bin"
mkdir -p "$fake_bin"
/usr/bin/printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "Identifier=com.henryvn27.Cowlick"' \
  'printf "%s\n" "CodeDirectory v=20500 flags=0x10000(runtime)"' \
  'printf "%s\n" "Authority=Developer ID Application: Cowlick Test (TESTTEAM00)"' \
  'printf "%s\n" "TeamIdentifier=TESTTEAM00"' \
  > "$fake_bin/codesign"
chmod 755 "$fake_bin/codesign"
PATH="$fake_bin:$PATH" zsh -c '
  set -euo pipefail
  source "$1"
  verify_code_identity /tmp/Cowlick.app Cowlick.app \
    "Developer ID Application: Cowlick Test (TESTTEAM00)" TESTTEAM00
' zsh "$script_dir/release_common.sh"

for invalid_version in \
  '' '../1.0.0' 'v1.0.0' '01.0.0' '1.0' '1.0.0-beta.1' '1.0.0+4' '1.0.0/escape'; do
  if validate_release_version "$invalid_version" >/dev/null 2>&1; then
    print -u2 -- "invalid version unexpectedly passed: $invalid_version"
    exit 1
  fi
done

missing_output="$temporary_directory/missing-environment.txt"
if env -i PATH="$PATH" HOME="$HOME" \
  "$script_dir/release_preflight.sh" 1.0.0 --distribution >"$missing_output" 2>&1; then
  print -u2 -- "distribution preflight unexpectedly passed without credentials"
  exit 1
fi
for variable_name in \
  DEVELOPER_ID_APPLICATION DEVELOPMENT_TEAM NOTARYTOOL_PROFILE SPARKLE_PRIVATE_KEY; do
  grep -q "$variable_name" "$missing_output" \
    || { print -u2 -- "missing environment report omitted $variable_name"; exit 1; }
done

artifact_fixture="$temporary_directory/artifacts"
mkdir -p "$artifact_fixture"
for artifact in Cowlick-1.0.0.zip Cowlick-1.0.0.dmg; do
  print -n -- 'not-a-release' > "$artifact_fixture/$artifact"
done
print -- '<rss />' > "$artifact_fixture/appcast.xml"
print -- "$(printf '0%.0s' {1..64})  Cowlick-1.0.0.zip" > "$artifact_fixture/checksums.txt"
print -- "$(printf '0%.0s' {1..64})  Cowlick-1.0.0.dmg" >> "$artifact_fixture/checksums.txt"
artifact_failure="$temporary_directory/artifact-failure.txt"
if "$script_dir/verify_release_artifacts.sh" 1.0.0 "$artifact_fixture" \
  >"$artifact_failure" 2>&1; then
  print -u2 -- "invalid release artifacts unexpectedly passed"
  exit 1
fi
grep -Fq 'SHA-256 mismatch for Cowlick-1.0.0.zip' "$artifact_failure"

fake_dmg="$temporary_directory/Cowlick-1.0.0.dmg"
print -n -- 'cowlick-release-fixture' > "$fake_dmg"
cask="$temporary_directory/cowlick.rb"
"$script_dir/render_homebrew_cask.sh" 1.0.0 "$fake_dmg" "$cask" >/dev/null
expected_sha="$(shasum -a 256 "$fake_dmg" | awk '{print $1}')"
grep -q "version \"1.0.0\"" "$cask"
grep -q "sha256 \"$expected_sha\"" "$cask"
grep -q 'app "Cowlick.app"' "$cask"
grep -q 'auto_updates true' "$cask"
grep -Fq 'Homebrew cannot declaratively remove Keychain items' "$cask"
grep -Fq 'Before uninstalling, choose Remove Integration in Cowlick Settings.' "$cask"
if grep -Fq '"~/Library/Application Support/Cowlick",' "$cask"; then
  print -u2 -- "Homebrew zap would orphan provider credentials by deleting their metadata"
  exit 1
fi
if grep -q '__VERSION__\|__SHA256__\|NotchRelay\|notchrelay\|Forelock\|forelock' "$cask"; then
  print -u2 -- "rendered cask contains an unresolved or legacy product value"
  exit 1
fi

uninstall_script="$script_dir/uninstall_local.sh"
purge_line="$(grep -n 'purge_provider_credentials.swift' "$uninstall_script" | cut -d: -f1)"
metadata_removal_line="$(grep -n 'rm -rf "\$HOME/Library/Application Support/Cowlick"' "$uninstall_script" | cut -d: -f1)"
[[ -n "$purge_line" && -n "$metadata_removal_line" && "$purge_line" -lt "$metadata_removal_line" ]] \
  || { print -u2 -- "provider credentials are not purged before account metadata"; exit 1; }

uninstall_home="$temporary_directory/uninstall-home"
uninstall_fake_bin="$temporary_directory/uninstall-bin"
uninstall_helper="$temporary_directory/uninstall-helper"
mkdir -p "$uninstall_home/.codex" "$uninstall_home/Applications/Cowlick.app"
mkdir -p "$uninstall_home/Library/Application Support/Cowlick"
mkdir -p "$uninstall_home/Library/Preferences" "$uninstall_fake_bin"
print -n -- '{"future":{"preserve":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/unrelated"}]}]}}' \
  > "$uninstall_home/.codex/hooks.json"
print -n -- '#!/bin/zsh\nexit 0\n' > "$uninstall_helper"
chmod 755 "$uninstall_helper"
print -n -- '#!/bin/zsh\nexit 1\n' > "$uninstall_fake_bin/pgrep"
chmod 755 "$uninstall_fake_bin/pgrep"
real_swift="$(command -v swift)"
print -r -- '#!/bin/zsh
set -euo pipefail

pause_at_barrier() {
  local phase="$1"
  local call="$2"
  [[ "${COWLICK_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ "${COWLICK_TEST_PAUSE_CALL:-}" == "$call" ]] || return 0
  : > "$COWLICK_TEST_BARRIER_DIRECTORY/reached"
  for _ in {1..500}; do
    [[ -e "$COWLICK_TEST_BARRIER_DIRECTORY/continue" ]] && return 0
    sleep 0.01
  done
  print -u2 "timed out waiting to continue the integration command"
  exit 1
}

if (( $# >= 2 )) && [[ "$1" == */install_hooks.swift && "$2" == restore ]] \
  && [[ "${COWLICK_TEST_RESTORE_FAIL:-}" == 1 ]]; then
  print -u2 "forced integration restore failure"
  exit 73
fi

if (( $# >= 2 )) && [[ "$1" == */install_hooks.swift && "$2" == install ]] \
  && [[ "${COWLICK_TEST_INSTALL_CHILD_FAIL_AFTER_MUTATION:-}" == 1 ]]; then
  "$COWLICK_TEST_REAL_SWIFT" "$@"
  print -u2 "forced child failure after integration mutation and failed internal rollback"
  exit 71
fi

if (( $# >= 2 )) && [[ "$1" == */install_hooks.swift && "$2" == install ]] \
  && [[ "${COWLICK_TEST_INSTALL_CHILD_DANGLING_MARKER:-}" == 1 ]]; then
  "$COWLICK_TEST_REAL_SWIFT" "$@"
  snapshot=""
  for (( index = 3; index <= $#; index += 1 )); do
    if [[ "${@[index]}" == --snapshot && $(( index + 1 )) -le $# ]]; then
      snapshot="${@[$(( index + 1 ))]}"
      break
    fi
  done
  [[ -n "$snapshot" ]]
  /bin/rm -f "$snapshot/.cowlick-integration-snapshot-v1"
  ln -s "$snapshot/missing-marker" "$snapshot/.cowlick-integration-snapshot-v1"
  print -u2 "forced child failure with a dangling integration snapshot marker"
  exit 72
fi

if (( $# >= 2 )) && [[ "$1" == */install_hooks.swift ]] \
  && [[ "$2" == "${COWLICK_TEST_BARRIER_COMMAND:-}" ]] \
  && [[ -n "${COWLICK_TEST_BARRIER_DIRECTORY:-}" ]]; then
  count_file="$COWLICK_TEST_BARRIER_DIRECTORY/$2-count"
  count=0
  [[ -f "$count_file" ]] && IFS= read -r count < "$count_file"
  (( count += 1 ))
  print -- "$count" > "$count_file"
  pause_at_barrier before "$count"
  "$COWLICK_TEST_REAL_SWIFT" "$@"
  pause_at_barrier after "$count"
  exit 0
fi

exec "$COWLICK_TEST_REAL_SWIFT" "$@"
' > "$uninstall_fake_bin/swift"
chmod 755 "$uninstall_fake_bin/swift"
print -r -- '#!/bin/zsh
set -euo pipefail
[[ "${1:-}" == swiftc ]] || exit 64
output=""
while (( $# > 0 )); do
  if [[ "$1" == -o ]]; then
    output="$2"
    break
  fi
  shift
done
[[ -n "$output" ]]
print -r -- "#!/bin/zsh" > "$output"
print -r -- "exit 0" >> "$output"
chmod 755 "$output"
' > "$uninstall_fake_bin/xcrun"
chmod 755 "$uninstall_fake_bin/xcrun"
print -n -- '#!/bin/zsh\nexit 0\n' > "$uninstall_fake_bin/defaults"
chmod 755 "$uninstall_fake_bin/defaults"
print -n -- 'preserve-local-state' \
  > "$uninstall_home/Library/Application Support/Cowlick/preserved-state"
print -n -- 'onboardingComplete=true' \
  > "$uninstall_home/Library/Preferences/com.henryvn27.Cowlick.plist"
print -n -- 'installed-app' > "$uninstall_home/Applications/Cowlick.app/marker"
COWLICK_HOME="$uninstall_home" swift "$script_dir/install_hooks.swift" \
  install --helper "$uninstall_helper" >/dev/null

uninstall_hooks_hash="$(shasum -a 256 "$uninstall_home/.codex/hooks.json" | awk '{print $1}')"
uninstall_helper_hash="$(shasum -a 256 \
  "$uninstall_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')"
assert_uninstall_fixture_intact() {
  [[ "$(shasum -a 256 "$uninstall_home/.codex/hooks.json" | awk '{print $1}')" \
      == "$uninstall_hooks_hash" ]]
  [[ "$(shasum -a 256 \
      "$uninstall_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')" \
      == "$uninstall_helper_hash" ]]
  [[ -L "$uninstall_home/.local/bin/cowlick-hook" ]]
  [[ -f "$uninstall_home/Applications/Cowlick.app/marker" ]]
}

uninstall_help="$temporary_directory/uninstall-help.txt"
env PATH="$uninstall_fake_bin:$PATH" HOME="$uninstall_home" COWLICK_HOME="$uninstall_home" \
  TMPDIR="$temporary_directory" "$uninstall_script" --help > "$uninstall_help"
grep -Fq 'usage:' "$uninstall_help"
assert_uninstall_fixture_intact

uninstall_unknown="$temporary_directory/uninstall-unknown.txt"
if env PATH="$uninstall_fake_bin:$PATH" HOME="$uninstall_home" COWLICK_HOME="$uninstall_home" \
  TMPDIR="$temporary_directory" "$uninstall_script" --unknown > "$uninstall_unknown" 2>&1; then
  print -u2 -- "unknown uninstall argument unexpectedly performed an uninstall"
  exit 1
fi
grep -Fq 'usage:' "$uninstall_unknown"
assert_uninstall_fixture_intact

env PATH="$uninstall_fake_bin:$PATH" HOME="$uninstall_home" COWLICK_HOME="$uninstall_home" \
  TMPDIR="$temporary_directory" COWLICK_TEST_REAL_SWIFT="$real_swift" \
  "$uninstall_script" >/dev/null
[[ ! -e "$uninstall_home/Applications/Cowlick.app" ]]
[[ ! -e "$uninstall_home/.local/bin/cowlick-hook" \
  && ! -L "$uninstall_home/.local/bin/cowlick-hook" ]]
[[ ! -e "$uninstall_home/Library/Application Support/Cowlick/bin/cowlick-hook" ]]
grep -Fq '/usr/local/bin/unrelated' "$uninstall_home/.codex/hooks.json"
if grep -Fq 'cowlick-hook' "$uninstall_home/.codex/hooks.json"; then
  print -u2 -- "normal uninstall left a Cowlick hook entry"
  exit 1
fi
grep -Fq 'preserve-local-state' \
  "$uninstall_home/Library/Application Support/Cowlick/preserved-state"
grep -Fq 'onboardingComplete=true' \
  "$uninstall_home/Library/Preferences/com.henryvn27.Cowlick.plist"
COWLICK_HOME="$uninstall_home" swift "$script_dir/install_hooks.swift" \
  install --helper "$uninstall_helper" >/dev/null
[[ "$(COWLICK_HOME="$uninstall_home" swift "$script_dir/install_hooks.swift" status)" \
    == "healthy" ]]

prepare_concurrent_uninstall_fixture() {
  local home="$1"
  mkdir -p "$home/.codex" "$home/Applications/Cowlick.app"
  mkdir -p "$home/Library/Application Support/Cowlick"
  print -n -- \
    '{"future":{"preserve":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/unrelated"}]}]}}' \
    > "$home/.codex/hooks.json"
  print -n -- 'preserve-local-state' \
    > "$home/Library/Application Support/Cowlick/preserved-state"
  COWLICK_HOME="$home" "$real_swift" "$script_dir/install_hooks.swift" \
    install --helper "$uninstall_helper" >/dev/null
}

start_uninstall_at_barrier() {
  local home="$1"
  local mode="$2"
  local phase="$3"
  local call="$4"
  local barrier="$5"
  local arguments=()
  [[ "$mode" == purge ]] && arguments=(--purge)
  mkdir -p "$barrier"
  env PATH="$uninstall_fake_bin:$PATH" HOME="$home" COWLICK_HOME="$home" \
    TMPDIR="$temporary_directory" COWLICK_TEST_REAL_SWIFT="$real_swift" \
    COWLICK_TEST_BARRIER_COMMAND=remove COWLICK_TEST_PAUSE_PHASE="$phase" \
    COWLICK_TEST_PAUSE_CALL="$call" COWLICK_TEST_BARRIER_DIRECTORY="$barrier" \
    "$uninstall_script" "${arguments[@]}" > "$barrier/output" 2>&1 &
  concurrent_uninstall_pid=$!
}

wait_for_uninstall_barrier() {
  local barrier="$1"
  for _ in {1..500}; do
    [[ -e "$barrier/reached" ]] && return
    if ! kill -0 "$concurrent_uninstall_pid" 2>/dev/null; then
      print -u2 -- "$(< "$barrier/output")"
      return 1
    fi
    sleep 0.01
  done
  print -u2 "timed out waiting for uninstall integration barrier"
  return 1
}

finish_uninstall_from_barrier() {
  local barrier="$1"
  : > "$barrier/continue"
  if ! wait "$concurrent_uninstall_pid"; then
    print -u2 -- "$(< "$barrier/output")"
    return 1
  fi
}

assert_integration_installed() {
  local home="$1"
  [[ "$(COWLICK_HOME="$home" "$real_swift" "$script_dir/install_hooks.swift" status)" \
      == healthy ]]
  [[ -L "$home/.local/bin/cowlick-hook" ]]
  [[ -f "$home/Library/Application Support/Cowlick/bin/cowlick-hook" ]]
}

assert_integration_removed() {
  local home="$1"
  [[ ! -e "$home/.local/bin/cowlick-hook" && ! -L "$home/.local/bin/cowlick-hook" ]]
  [[ ! -e "$home/Library/Application Support/Cowlick/bin/cowlick-hook" ]]
  grep -Fq '/usr/local/bin/unrelated' "$home/.codex/hooks.json"
  if grep -Fq 'cowlick-hook' "$home/.codex/hooks.json"; then
    print -u2 "uninstall concurrency fixture retained a Cowlick hook"
    return 1
  fi
}

normal_install_first_home="$temporary_directory/normal-install-first"
normal_install_first_barrier="$temporary_directory/normal-install-first-barrier"
prepare_concurrent_uninstall_fixture "$normal_install_first_home"
start_uninstall_at_barrier \
  "$normal_install_first_home" normal before 1 "$normal_install_first_barrier"
wait_for_uninstall_barrier "$normal_install_first_barrier"
COWLICK_HOME="$normal_install_first_home" "$real_swift" "$script_dir/install_hooks.swift" \
  install --helper "$uninstall_helper" >/dev/null
finish_uninstall_from_barrier "$normal_install_first_barrier"
assert_integration_removed "$normal_install_first_home"

normal_uninstall_first_home="$temporary_directory/normal-uninstall-first"
normal_uninstall_first_barrier="$temporary_directory/normal-uninstall-first-barrier"
prepare_concurrent_uninstall_fixture "$normal_uninstall_first_home"
start_uninstall_at_barrier \
  "$normal_uninstall_first_home" normal after 1 "$normal_uninstall_first_barrier"
wait_for_uninstall_barrier "$normal_uninstall_first_barrier"
COWLICK_HOME="$normal_uninstall_first_home" "$real_swift" "$script_dir/install_hooks.swift" \
  install --helper "$uninstall_helper" >/dev/null
finish_uninstall_from_barrier "$normal_uninstall_first_barrier"
assert_integration_installed "$normal_uninstall_first_home"

purge_install_first_home="$temporary_directory/purge-install-first"
purge_install_first_barrier="$temporary_directory/purge-install-first-barrier"
prepare_concurrent_uninstall_fixture "$purge_install_first_home"
start_uninstall_at_barrier \
  "$purge_install_first_home" purge after 1 "$purge_install_first_barrier"
wait_for_uninstall_barrier "$purge_install_first_barrier"
COWLICK_HOME="$purge_install_first_home" "$real_swift" "$script_dir/install_hooks.swift" \
  install --helper "$uninstall_helper" >/dev/null
finish_uninstall_from_barrier "$purge_install_first_barrier"
assert_integration_removed "$purge_install_first_home"
[[ ! -e "$purge_install_first_home/Library/Application Support/Cowlick" ]]

purge_uninstall_first_home="$temporary_directory/purge-uninstall-first"
purge_uninstall_first_barrier="$temporary_directory/purge-uninstall-first-barrier"
prepare_concurrent_uninstall_fixture "$purge_uninstall_first_home"
start_uninstall_at_barrier \
  "$purge_uninstall_first_home" purge after 2 "$purge_uninstall_first_barrier"
wait_for_uninstall_barrier "$purge_uninstall_first_barrier"
COWLICK_HOME="$purge_uninstall_first_home" "$real_swift" "$script_dir/install_hooks.swift" \
  install --helper "$uninstall_helper" >/dev/null
finish_uninstall_from_barrier "$purge_uninstall_first_barrier"
assert_integration_installed "$purge_uninstall_first_home"

rollback_old_helper="$temporary_directory/rollback-old-helper"
rollback_new_helper="$temporary_directory/rollback-new-helper"
print -n -- '#!/bin/zsh\nprint old-helper\n' > "$rollback_old_helper"
print -n -- '#!/bin/zsh\nprint new-helper\n' > "$rollback_new_helper"
chmod 755 "$rollback_old_helper" "$rollback_new_helper"

prepare_rollback_fixture() {
  local home="$1"
  local snapshot="$2"
  mkdir -p "$home/.codex"
  print -n -- \
    '{"future":{"preserve":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/unrelated"}]}]}}' \
    > "$home/.codex/hooks.json"
  COWLICK_HOME="$home" "$real_swift" "$script_dir/install_hooks.swift" \
    install --helper "$rollback_old_helper" >/dev/null
  COWLICK_HOME="$home" "$real_swift" "$script_dir/install_hooks.swift" \
    install --helper "$rollback_new_helper" --snapshot "$snapshot" >/dev/null
}

start_restore_at_barrier() {
  local home="$1"
  local snapshot="$2"
  local phase="$3"
  local barrier="$4"
  mkdir -p "$barrier"
  env PATH="$uninstall_fake_bin:$PATH" COWLICK_HOME="$home" \
    COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_BARRIER_COMMAND=restore \
    COWLICK_TEST_PAUSE_PHASE="$phase" COWLICK_TEST_PAUSE_CALL=1 \
    COWLICK_TEST_BARRIER_DIRECTORY="$barrier" swift "$script_dir/install_hooks.swift" \
    restore --snapshot "$snapshot" > "$barrier/output" 2>&1 &
  concurrent_uninstall_pid=$!
}

install_before_rollback_home="$temporary_directory/install-before-rollback"
install_before_rollback_snapshot="$temporary_directory/install-before-rollback-snapshot"
install_before_rollback_barrier="$temporary_directory/install-before-rollback-barrier"
prepare_rollback_fixture "$install_before_rollback_home" "$install_before_rollback_snapshot"
start_restore_at_barrier "$install_before_rollback_home" \
  "$install_before_rollback_snapshot" before "$install_before_rollback_barrier"
wait_for_uninstall_barrier "$install_before_rollback_barrier"
COWLICK_HOME="$install_before_rollback_home" "$real_swift" \
  "$script_dir/install_hooks.swift" install --helper "$rollback_new_helper" >/dev/null
finish_uninstall_from_barrier "$install_before_rollback_barrier"
grep -Fq 'old-helper' \
  "$install_before_rollback_home/Library/Application Support/Cowlick/bin/cowlick-hook"

rollback_before_install_home="$temporary_directory/rollback-before-install"
rollback_before_install_snapshot="$temporary_directory/rollback-before-install-snapshot"
rollback_before_install_barrier="$temporary_directory/rollback-before-install-barrier"
prepare_rollback_fixture "$rollback_before_install_home" "$rollback_before_install_snapshot"
start_restore_at_barrier "$rollback_before_install_home" \
  "$rollback_before_install_snapshot" after "$rollback_before_install_barrier"
wait_for_uninstall_barrier "$rollback_before_install_barrier"
COWLICK_HOME="$rollback_before_install_home" "$real_swift" \
  "$script_dir/install_hooks.swift" install --helper "$rollback_new_helper" >/dev/null
finish_uninstall_from_barrier "$rollback_before_install_barrier"
grep -Fq 'new-helper' \
  "$rollback_before_install_home/Library/Application Support/Cowlick/bin/cowlick-hook"

wrapper_project="$temporary_directory/wrapper-project"
wrapper_scripts="$wrapper_project/Scripts"
wrapper_fake_bin="$temporary_directory/wrapper-bin"
mkdir -p "$wrapper_scripts" "$wrapper_fake_bin"
cp "$script_dir/install_local.sh" "$script_dir/uninstall_local.sh" \
  "$script_dir/install_hooks.swift" "$wrapper_scripts/"
cp "$uninstall_fake_bin/swift" "$wrapper_fake_bin/swift"
chmod 755 "$wrapper_fake_bin/swift"
for command_name in pgrep open xcodegen; do
  print -n -- '#!/bin/zsh\nexit 0\n' > "$wrapper_fake_bin/$command_name"
  chmod 755 "$wrapper_fake_bin/$command_name"
done
rollback_remove_command="$wrapper_fake_bin/rollback-remove"
rollback_move_command="$wrapper_fake_bin/rollback-move"
print -r -- '#!/bin/zsh
set -euo pipefail
case "${COWLICK_TEST_ROLLBACK_REMOVE_RESULT:-}" in
  fail) exit 74 ;;
  false-success) exit 0 ;;
  dangling-success)
    destination="${@[-1]}"
    /bin/rm "$@"
    ln -s /nonexistent-cowlick-app "$destination"
    exit 0
    ;;
  *) exec /bin/rm "$@" ;;
esac
' > "$rollback_remove_command"
print -r -- '#!/bin/zsh
set -euo pipefail
case "${COWLICK_TEST_ROLLBACK_MOVE_RESULT:-}" in
  fail) exit 75 ;;
  false-success) exit 0 ;;
  *) exec /bin/mv "$@" ;;
esac
' > "$rollback_move_command"
chmod 755 "$rollback_remove_command" "$rollback_move_command"
COWLICK_TEST_WRAPPER="$wrapper_scripts/install_local.sh" \
  COWLICK_TEST_ROLLBACK_REMOVE="$rollback_remove_command" \
  COWLICK_TEST_ROLLBACK_MOVE="$rollback_move_command" "$real_swift" -e '
    import Foundation

    let environment = ProcessInfo.processInfo.environment
    let path = environment["COWLICK_TEST_WRAPPER"]!
    var script = try String(contentsOfFile: path, encoding: .utf8)
    let removeSource = #"/bin/rm -rf "$destination" || destination_removed=false"#
    let removeReplacement =
      "\"\(environment["COWLICK_TEST_ROLLBACK_REMOVE"]!)\" -rf \"$destination\" || destination_removed=false"
    let moveSource = #"/bin/mv "$backup" "$destination" || move_exit_code=$?"#
    let moveReplacement =
      "\"\(environment["COWLICK_TEST_ROLLBACK_MOVE"]!)\" \"$backup\" \"$destination\" || move_exit_code=$?"
    precondition(script.components(separatedBy: removeSource).count == 2)
    precondition(script.components(separatedBy: moveSource).count == 2)
    script = script.replacingOccurrences(of: removeSource, with: removeReplacement)
    script = script.replacingOccurrences(of: moveSource, with: moveReplacement)
    try script.write(toFile: path, atomically: true, encoding: .utf8)
  '
chmod 755 "$wrapper_scripts/install_local.sh"
print -r -- '#!/bin/zsh
set -euo pipefail
derived_data=""
while (( $# > 0 )); do
  if [[ "$1" == -derivedDataPath ]]; then
    derived_data="$2"
    break
  fi
  shift
done
[[ -n "$derived_data" ]]
helper="$derived_data/Build/Products/Release/Cowlick.app/Contents/Helpers/cowlick-hook"
mkdir -p "${helper:h}"
print -r -- "#!/bin/zsh" > "$helper"
print -r -- "# ${COWLICK_TEST_HELPER_MARKER:-wrapper-helper}" >> "$helper"
print -r -- "exit 0" >> "$helper"
chmod 755 "$helper"
if [[ -n "${COWLICK_TEST_XCODEBUILD_BARRIER_DIRECTORY:-}" ]]; then
  : > "$COWLICK_TEST_XCODEBUILD_BARRIER_DIRECTORY/reached"
  for _ in {1..500}; do
    [[ -e "$COWLICK_TEST_XCODEBUILD_BARRIER_DIRECTORY/continue" ]] && exit 0
    sleep 0.01
  done
  print -u2 "timed out waiting to continue the local build"
  exit 1
fi
' > "$wrapper_fake_bin/xcodebuild"
chmod 755 "$wrapper_fake_bin/xcodebuild"
print -n -- \
  '#!/bin/zsh\n[[ "${COWLICK_TEST_VERIFY_FAIL:-}" == 1 ]] && exit 1\nexit 0\n' \
  > "$wrapper_scripts/verify_installation.sh"
chmod 755 "$wrapper_scripts/verify_installation.sh"

wrapper_argument_home="$temporary_directory/wrapper-argument-home"
wrapper_help_output="$temporary_directory/wrapper-install-help"
env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_argument_home" \
  COWLICK_HOME="$wrapper_argument_home" TMPDIR="$temporary_directory" \
  "$wrapper_scripts/install_local.sh" --help > "$wrapper_help_output"
grep -Fq 'usage:' "$wrapper_help_output"
[[ ! -e "$wrapper_argument_home" ]]
for invalid_arguments in '--unknown' 'extra' '--help extra'; do
  if env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_argument_home" \
    COWLICK_HOME="$wrapper_argument_home" TMPDIR="$temporary_directory" \
    "$wrapper_scripts/install_local.sh" ${(z)invalid_arguments} >/dev/null 2>&1; then
    print -u2 "invalid local installer arguments unexpectedly succeeded: $invalid_arguments"
    exit 1
  fi
  [[ ! -e "$wrapper_argument_home" ]]
done

assert_invalid_wrapper_hooks_roll_back() {
  local name="$1"
  local payload="$2"
  local home="$temporary_directory/wrapper-invalid-$name-home"
  local output="$temporary_directory/wrapper-invalid-$name-output"
  local app_helper="$home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
  local installed_helper="$home/Library/Application Support/Cowlick/bin/cowlick-hook"
  local shim="$home/.local/bin/cowlick-hook"
  local hooks="$home/.codex/hooks.json"
  mkdir -p "${app_helper:h}" "${installed_helper:h}" "${shim:h}" "${hooks:h}"
  print -n -- "old-app-$name" > "$home/Applications/Cowlick.app/marker"
  print -r -- '#!/bin/zsh' > "$app_helper"
  print -r -- "# old-app-helper-$name" >> "$app_helper"
  print -r -- 'exit 0' >> "$app_helper"
  print -r -- '#!/bin/zsh' > "$installed_helper"
  print -r -- "# old-installed-helper-$name" >> "$installed_helper"
  print -r -- 'exit 0' >> "$installed_helper"
  chmod 755 "$app_helper" "$installed_helper"
  ln -s "$installed_helper" "$shim"
  print -n -- "$payload" > "$hooks"
  local hooks_hash="$(shasum -a 256 "$hooks" | awk '{print $1}')"
  local helper_hash="$(shasum -a 256 "$installed_helper" | awk '{print $1}')"

  if env PATH="$wrapper_fake_bin:$PATH" HOME="$home" COWLICK_HOME="$home" \
    TMPDIR="$temporary_directory" COWLICK_TEST_REAL_SWIFT="$real_swift" \
    COWLICK_TEST_HELPER_MARKER="new-$name" \
    "$wrapper_scripts/install_local.sh" > "$output" 2>&1; then
    print -u2 "$name hooks unexpectedly allowed a local install"
    exit 1
  fi
  grep -Fq 'Local installation failed; restoring the previous Cowlick installation.' "$output"
  grep -Fq "old-app-$name" "$home/Applications/Cowlick.app/marker"
  grep -Fq "old-app-helper-$name" \
    "$home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
  [[ "$(shasum -a 256 "$installed_helper" | awk '{print $1}')" == "$helper_hash" ]]
  [[ "$(shasum -a 256 "$hooks" | awk '{print $1}')" == "$hooks_hash" ]]
  [[ -L "$shim" && "$(readlink "$shim")" == "$installed_helper" ]]
  [[ -z "$(find "$home/Applications" -maxdepth 1 -name 'Cowlick.app.backup-*' -print -quit)" ]]
}

assert_invalid_wrapper_hooks_roll_back malformed '{'
assert_invalid_wrapper_hooks_roll_back non-object '[]'

wait_for_process_barrier() {
  local barrier="$1"
  local process_id="$2"
  local output="$3"
  for _ in {1..500}; do
    [[ -e "$barrier/reached" ]] && return
    if ! kill -0 "$process_id" 2>/dev/null; then
      print -u2 -- "$(< "$output")"
      return 1
    fi
    sleep 0.01
  done
  print -u2 "timed out waiting for local lifecycle barrier"
  return 1
}

assert_local_install_present() {
  local home="$1"
  [[ -d "$home/Applications/Cowlick.app" ]]
  assert_integration_installed "$home"
}

assert_local_install_removed() {
  local home="$1"
  [[ ! -e "$home/Applications/Cowlick.app" ]]
  [[ ! -e "$home/.local/bin/cowlick-hook" && ! -L "$home/.local/bin/cowlick-hook" ]]
  [[ ! -e "$home/Library/Application Support/Cowlick/bin/cowlick-hook" ]]
  ! grep -Fq 'cowlick-hook' "$home/.codex/hooks.json"
}

wrapper_install_first_home="$temporary_directory/wrapper-install-first-home"
wrapper_install_first_barrier="$temporary_directory/wrapper-install-first-barrier"
wrapper_install_first_output="$temporary_directory/wrapper-install-first-output"
wrapper_uninstall_second_output="$temporary_directory/wrapper-uninstall-second-output"
mkdir -p "$wrapper_install_first_barrier"
env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_install_first_home" \
  COWLICK_HOME="$wrapper_install_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=install-first \
  COWLICK_TEST_XCODEBUILD_BARRIER_DIRECTORY="$wrapper_install_first_barrier" \
  "$wrapper_scripts/install_local.sh" > "$wrapper_install_first_output" 2>&1 &
wrapper_install_pid=$!
wait_for_process_barrier \
  "$wrapper_install_first_barrier" "$wrapper_install_pid" "$wrapper_install_first_output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_install_first_home" \
  COWLICK_HOME="$wrapper_install_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" "$wrapper_scripts/uninstall_local.sh" \
  > "$wrapper_uninstall_second_output" 2>&1 &
wrapper_uninstall_pid=$!
kill -0 "$wrapper_uninstall_pid"
: > "$wrapper_install_first_barrier/continue"
wait "$wrapper_install_pid"
wait "$wrapper_uninstall_pid"
assert_local_install_removed "$wrapper_install_first_home"

wrapper_uninstall_first_home="$temporary_directory/wrapper-uninstall-first-home"
wrapper_uninstall_first_barrier="$temporary_directory/wrapper-uninstall-first-barrier"
wrapper_uninstall_first_output="$temporary_directory/wrapper-uninstall-first-output"
wrapper_install_second_output="$temporary_directory/wrapper-install-second-output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_uninstall_first_home" \
  COWLICK_HOME="$wrapper_uninstall_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=initial-install \
  "$wrapper_scripts/install_local.sh" >/dev/null
mkdir -p "$wrapper_uninstall_first_barrier"
env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_uninstall_first_home" \
  COWLICK_HOME="$wrapper_uninstall_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_BARRIER_COMMAND=remove \
  COWLICK_TEST_PAUSE_PHASE=after COWLICK_TEST_PAUSE_CALL=1 \
  COWLICK_TEST_BARRIER_DIRECTORY="$wrapper_uninstall_first_barrier" \
  "$wrapper_scripts/uninstall_local.sh" > "$wrapper_uninstall_first_output" 2>&1 &
wrapper_uninstall_pid=$!
wait_for_process_barrier \
  "$wrapper_uninstall_first_barrier" "$wrapper_uninstall_pid" "$wrapper_uninstall_first_output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$wrapper_uninstall_first_home" \
  COWLICK_HOME="$wrapper_uninstall_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=install-second \
  "$wrapper_scripts/install_local.sh" > "$wrapper_install_second_output" 2>&1 &
wrapper_install_pid=$!
kill -0 "$wrapper_install_pid"
: > "$wrapper_uninstall_first_barrier/continue"
wait "$wrapper_uninstall_pid"
wait "$wrapper_install_pid"
assert_local_install_present "$wrapper_uninstall_first_home"
grep -Fq 'install-second' \
  "$wrapper_uninstall_first_home/Library/Application Support/Cowlick/bin/cowlick-hook"

rollback_first_home="$temporary_directory/wrapper-rollback-first-home"
rollback_first_barrier="$temporary_directory/wrapper-rollback-first-barrier"
rollback_first_output="$temporary_directory/wrapper-rollback-first-output"
install_after_rollback_output="$temporary_directory/wrapper-install-after-rollback-output"
mkdir -p "$rollback_first_barrier"
env PATH="$wrapper_fake_bin:$PATH" HOME="$rollback_first_home" \
  COWLICK_HOME="$rollback_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=failed-first \
  COWLICK_TEST_VERIFY_FAIL=1 \
  COWLICK_TEST_XCODEBUILD_BARRIER_DIRECTORY="$rollback_first_barrier" \
  "$wrapper_scripts/install_local.sh" > "$rollback_first_output" 2>&1 &
rollback_first_pid=$!
wait_for_process_barrier "$rollback_first_barrier" "$rollback_first_pid" "$rollback_first_output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$rollback_first_home" \
  COWLICK_HOME="$rollback_first_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=installed-after-rollback \
  "$wrapper_scripts/install_local.sh" > "$install_after_rollback_output" 2>&1 &
install_after_rollback_pid=$!
: > "$rollback_first_barrier/continue"
if wait "$rollback_first_pid"; then
  print -u2 "failed local install unexpectedly succeeded"
  exit 1
fi
wait "$install_after_rollback_pid"
assert_local_install_present "$rollback_first_home"
grep -Fq 'installed-after-rollback' \
  "$rollback_first_home/Library/Application Support/Cowlick/bin/cowlick-hook"

install_before_rollback_home="$temporary_directory/wrapper-install-before-rollback-home"
install_before_rollback_barrier="$temporary_directory/wrapper-install-before-rollback-barrier"
install_before_rollback_output="$temporary_directory/wrapper-install-before-rollback-output"
rollback_after_install_output="$temporary_directory/wrapper-rollback-after-install-output"
mkdir -p "$install_before_rollback_barrier"
env PATH="$wrapper_fake_bin:$PATH" HOME="$install_before_rollback_home" \
  COWLICK_HOME="$install_before_rollback_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=retained-install \
  COWLICK_TEST_XCODEBUILD_BARRIER_DIRECTORY="$install_before_rollback_barrier" \
  "$wrapper_scripts/install_local.sh" > "$install_before_rollback_output" 2>&1 &
install_before_rollback_pid=$!
wait_for_process_barrier "$install_before_rollback_barrier" \
  "$install_before_rollback_pid" "$install_before_rollback_output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$install_before_rollback_home" \
  COWLICK_HOME="$install_before_rollback_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=failed-after-install \
  COWLICK_TEST_VERIFY_FAIL=1 "$wrapper_scripts/install_local.sh" \
  > "$rollback_after_install_output" 2>&1 &
rollback_after_install_pid=$!
: > "$install_before_rollback_barrier/continue"
wait "$install_before_rollback_pid"
if wait "$rollback_after_install_pid"; then
  print -u2 "failed local replacement unexpectedly succeeded"
  exit 1
fi
assert_local_install_present "$install_before_rollback_home"
grep -Fq 'retained-install' \
  "$install_before_rollback_home/Library/Application Support/Cowlick/bin/cowlick-hook"
grep -Fq 'retained-install' \
  "$install_before_rollback_home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"

restore_failure_home="$temporary_directory/wrapper-restore-failure-home"
restore_failure_output="$temporary_directory/wrapper-restore-failure-output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$restore_failure_home" \
  COWLICK_HOME="$restore_failure_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=before-restore-failure \
  "$wrapper_scripts/install_local.sh" >/dev/null
restore_failure_status=0
env PATH="$wrapper_fake_bin:$PATH" HOME="$restore_failure_home" \
  COWLICK_HOME="$restore_failure_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=failed-restore \
  COWLICK_TEST_VERIFY_FAIL=1 COWLICK_TEST_RESTORE_FAIL=1 \
  "$wrapper_scripts/install_local.sh" > "$restore_failure_output" 2>&1 \
  || restore_failure_status=$?
if (( restore_failure_status == 0 )); then
  print -u2 "local install unexpectedly survived forced integration restore failure"
  exit 1
fi
if (( restore_failure_status != 1 )); then
  print -u2 -- "local install replaced verify exit 1 with rollback exit $restore_failure_status"
  exit 1
fi
grep -Fq 'forced integration restore failure' "$restore_failure_output"
grep -Fq 'Cowlick integration restoration failed (exit 73).' "$restore_failure_output"
grep -Fq 'Previous local Cowlick app restored; integration restoration failed.' \
  "$restore_failure_output"
if grep -Fxq 'Previous local Cowlick app restored.' "$restore_failure_output"; then
  print -u2 "failed integration rollback claimed complete restoration"
  exit 1
fi
retained_snapshot="$(sed -n 's/^Rollback snapshot retained at //p' \
  "$restore_failure_output" | tail -1)"
[[ -n "$retained_snapshot" && -d "$retained_snapshot" ]]
grep -Fq 'before-restore-failure' "$retained_snapshot/cowlick-hook"
[[ -s "$retained_snapshot/hooks.json" ]]
grep -Fq 'before-restore-failure' \
  "$restore_failure_home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
grep -Fq 'failed-restore' \
  "$restore_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook"
retained_helper_hash="$(shasum -a 256 "$retained_snapshot/cowlick-hook" | awk '{print $1}')"
COWLICK_HOME="$restore_failure_home" "$real_swift" \
  "$wrapper_scripts/install_hooks.swift" restore --snapshot "$retained_snapshot" >/dev/null
assert_integration_installed "$restore_failure_home"
[[ "$(shasum -a 256 \
    "$restore_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook" \
    | awk '{print $1}')" == "$retained_helper_hash" ]]
grep -Fq 'before-restore-failure' \
  "$restore_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook"
[[ "$(readlink "$restore_failure_home/.local/bin/cowlick-hook")" \
    == "$restore_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook" ]]
[[ -d "$retained_snapshot" && -s "$retained_snapshot/hooks.json" ]]

child_failure_home="$temporary_directory/wrapper-child-failure-home"
child_failure_output="$temporary_directory/wrapper-child-failure-output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$child_failure_home" \
  COWLICK_HOME="$child_failure_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=before-child-failure \
  "$wrapper_scripts/install_local.sh" >/dev/null
child_failure_status=0
env PATH="$wrapper_fake_bin:$PATH" HOME="$child_failure_home" \
  COWLICK_HOME="$child_failure_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=mutated-child \
  COWLICK_TEST_INSTALL_CHILD_FAIL_AFTER_MUTATION=1 \
  "$wrapper_scripts/install_local.sh" > "$child_failure_output" 2>&1 \
  || child_failure_status=$?
[[ "$child_failure_status" == 71 ]]
grep -Fq 'forced child failure after integration mutation and failed internal rollback' \
  "$child_failure_output"
grep -Fxq 'Previous local Cowlick app restored.' "$child_failure_output"
assert_local_install_present "$child_failure_home"
grep -Fq 'before-child-failure' \
  "$child_failure_home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
grep -Fq 'before-child-failure' \
  "$child_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook"

child_outer_failure_home="$temporary_directory/wrapper-child-outer-failure-home"
child_outer_failure_output="$temporary_directory/wrapper-child-outer-failure-output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$child_outer_failure_home" \
  COWLICK_HOME="$child_outer_failure_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=before-child-outer-failure \
  "$wrapper_scripts/install_local.sh" >/dev/null
child_outer_failure_status=0
env PATH="$wrapper_fake_bin:$PATH" HOME="$child_outer_failure_home" \
  COWLICK_HOME="$child_outer_failure_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=mutated-child-outer \
  COWLICK_TEST_INSTALL_CHILD_FAIL_AFTER_MUTATION=1 COWLICK_TEST_RESTORE_FAIL=1 \
  "$wrapper_scripts/install_local.sh" > "$child_outer_failure_output" 2>&1 \
  || child_outer_failure_status=$?
[[ "$child_outer_failure_status" == 71 ]]
grep -Fq 'Cowlick integration restoration failed (exit 73).' "$child_outer_failure_output"
child_outer_snapshot="$(sed -n 's/^Rollback snapshot retained at //p' \
  "$child_outer_failure_output" | tail -1)"
[[ -d "$child_outer_snapshot" ]]
grep -Fq 'before-child-outer-failure' \
  "$child_outer_failure_home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
grep -Fq 'mutated-child-outer' \
  "$child_outer_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook"
COWLICK_HOME="$child_outer_failure_home" "$real_swift" \
  "$wrapper_scripts/install_hooks.swift" restore --snapshot "$child_outer_snapshot" >/dev/null
assert_local_install_present "$child_outer_failure_home"
grep -Fq 'before-child-outer-failure' \
  "$child_outer_failure_home/Library/Application Support/Cowlick/bin/cowlick-hook"

dangling_child_marker_home="$temporary_directory/wrapper-dangling-child-marker-home"
dangling_child_marker_output="$temporary_directory/wrapper-dangling-child-marker-output"
env PATH="$wrapper_fake_bin:$PATH" HOME="$dangling_child_marker_home" \
  COWLICK_HOME="$dangling_child_marker_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=before-dangling-marker \
  "$wrapper_scripts/install_local.sh" >/dev/null
dangling_child_marker_status=0
env PATH="$wrapper_fake_bin:$PATH" HOME="$dangling_child_marker_home" \
  COWLICK_HOME="$dangling_child_marker_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=mutated-dangling-marker \
  COWLICK_TEST_INSTALL_CHILD_DANGLING_MARKER=1 \
  "$wrapper_scripts/install_local.sh" > "$dangling_child_marker_output" 2>&1 \
  || dangling_child_marker_status=$?
[[ "$dangling_child_marker_status" == 72 ]]
grep -Fq 'forced child failure with a dangling integration snapshot marker' \
  "$dangling_child_marker_output"
grep -Fq 'Cowlick integration state is uncertain; no valid rollback snapshot is available.' \
  "$dangling_child_marker_output"
if grep -Fq 'Rollback snapshot retained at ' "$dangling_child_marker_output"; then
  print -u2 "invalid child marker was mislabeled as a retained rollback snapshot"
  exit 1
fi
dangling_child_workspace="$(sed -n 's/^Rollback workspace retained at //p' \
  "$dangling_child_marker_output" | tail -1)"
[[ -d "$dangling_child_workspace" ]]
[[ -L "$dangling_child_workspace/.cowlick-integration-snapshot-v1" ]]

assert_app_rollback_failure_retains_recovery() {
  local name="$1"
  local remove_result="$2"
  local move_result="$3"
  local home="$temporary_directory/wrapper-app-rollback-$name-home"
  local output="$temporary_directory/wrapper-app-rollback-$name-output"
  env PATH="$wrapper_fake_bin:$PATH" HOME="$home" COWLICK_HOME="$home" \
    TMPDIR="$temporary_directory" COWLICK_TEST_REAL_SWIFT="$real_swift" \
    COWLICK_TEST_HELPER_MARKER="before-$name" "$wrapper_scripts/install_local.sh" >/dev/null

  local wrapper_status=0
  env PATH="$wrapper_fake_bin:$PATH" HOME="$home" COWLICK_HOME="$home" \
    TMPDIR="$temporary_directory" COWLICK_TEST_REAL_SWIFT="$real_swift" \
    COWLICK_TEST_HELPER_MARKER="failed-$name" COWLICK_TEST_VERIFY_FAIL=1 \
    COWLICK_TEST_ROLLBACK_REMOVE_RESULT="$remove_result" \
    COWLICK_TEST_ROLLBACK_MOVE_RESULT="$move_result" \
    "$wrapper_scripts/install_local.sh" > "$output" 2>&1 || wrapper_status=$?
  [[ "$wrapper_status" == 1 ]]
  if grep -Fxq 'Previous local Cowlick app restored.' "$output"; then
    print -u2 "$name rollback falsely claimed full app restoration"
    exit 1
  fi
  local snapshot="$(sed -n 's/^Rollback snapshot retained at //p' "$output" | tail -1)"
  local retained_backup="$(sed -n 's/^Previous Cowlick app backup retained at //p' \
    "$output" | tail -1)"
  [[ -d "$snapshot" && -d "$retained_backup" ]]
  grep -Fq "before-$name" "$retained_backup/Contents/Helpers/cowlick-hook"
  grep -Fq "before-$name" \
    "$home/Library/Application Support/Cowlick/bin/cowlick-hook"
}

assert_app_rollback_failure_retains_recovery remove-failure fail ''
assert_app_rollback_failure_retains_recovery move-failure '' fail
assert_app_rollback_failure_retains_recovery move-false-success '' false-success
assert_app_rollback_failure_retains_recovery dangling-destination dangling-success ''
[[ -L "$temporary_directory/wrapper-app-rollback-dangling-destination-home/Applications/Cowlick.app" ]]

legacy_cleanup_home="$temporary_directory/wrapper-legacy-cleanup-home"
legacy_cleanup_output="$temporary_directory/wrapper-legacy-cleanup-output"
legacy_cleanup_app_helper="$legacy_cleanup_home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
legacy_cleanup_legacy_app="$legacy_cleanup_home/Applications/NotchRelay.app"
mkdir -p "${legacy_cleanup_app_helper:h}" "$legacy_cleanup_legacy_app"
print -n -- 'old-app-before-legacy-cleanup' \
  > "$legacy_cleanup_home/Applications/Cowlick.app/marker"
print -r -- '#!/bin/zsh' > "$legacy_cleanup_app_helper"
print -r -- '# old-helper-before-legacy-cleanup' >> "$legacy_cleanup_app_helper"
print -r -- 'exit 0' >> "$legacy_cleanup_app_helper"
chmod 755 "$legacy_cleanup_app_helper"
COWLICK_HOME="$legacy_cleanup_home" "$real_swift" "$wrapper_scripts/install_hooks.swift" \
  install --helper "$legacy_cleanup_app_helper" >/dev/null
legacy_cleanup_hooks_hash="$(shasum -a 256 "$legacy_cleanup_home/.codex/hooks.json" | awk '{print $1}')"
legacy_cleanup_helper_hash="$(shasum -a 256 \
  "$legacy_cleanup_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')"
print -n -- 'protected' > "$legacy_cleanup_legacy_app/protected"
chmod 500 "$legacy_cleanup_legacy_app"
if env PATH="$wrapper_fake_bin:$PATH" HOME="$legacy_cleanup_home" \
  COWLICK_HOME="$legacy_cleanup_home" TMPDIR="$temporary_directory" \
  COWLICK_TEST_REAL_SWIFT="$real_swift" COWLICK_TEST_HELPER_MARKER=failed-legacy-cleanup \
  "$wrapper_scripts/install_local.sh" > "$legacy_cleanup_output" 2>&1; then
  chmod 700 "$legacy_cleanup_legacy_app"
  print -u2 "local install unexpectedly survived failed legacy cleanup"
  exit 1
fi
chmod 700 "$legacy_cleanup_legacy_app"
grep -Fq 'Local installation failed; restoring the previous Cowlick installation.' \
  "$legacy_cleanup_output"
grep -Fq 'old-app-before-legacy-cleanup' \
  "$legacy_cleanup_home/Applications/Cowlick.app/marker"
grep -Fq 'old-helper-before-legacy-cleanup' \
  "$legacy_cleanup_home/Applications/Cowlick.app/Contents/Helpers/cowlick-hook"
[[ "$(shasum -a 256 "$legacy_cleanup_home/.codex/hooks.json" | awk '{print $1}')" \
    == "$legacy_cleanup_hooks_hash" ]]
[[ "$(shasum -a 256 \
    "$legacy_cleanup_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')" \
    == "$legacy_cleanup_helper_hash" ]]
[[ -L "$legacy_cleanup_home/.local/bin/cowlick-hook" ]]
[[ "$(COWLICK_HOME="$legacy_cleanup_home" "$real_swift" \
    "$wrapper_scripts/install_hooks.swift" status)" == healthy ]]
[[ -z "$(find "$legacy_cleanup_home/Applications" -maxdepth 1 \
    -name 'Cowlick.app.backup-*' -print -quit)" ]]

release_workflow="$project_root/.github/workflows/release.yml"
provenance_script="$script_dir/verify_release_provenance.sh"
package_script="$script_dir/package_release.sh"
artifact_verifier="$script_dir/verify_release_artifacts.sh"
create_release_script="$script_dir/create_release.sh"
tap_rollback_guard="$script_dir/release_tap_rollback_guard.sh"
mutation_runner="$script_dir/release_run_mutation.sh"
stability_guard="$script_dir/release_stability_guard.sh"
grep -Fq 'derived_data="$project_root/DerivedData"' "$package_script"
grep -Fq -- '-derivedDataPath "$derived_data"' "$package_script"
grep -Fq '"$script_dir/verify_release_artifacts.sh" "$version" "$output"' \
  "$create_release_script"
grep -Fq 'workflow_dispatch:' "$release_workflow"
grep -Fq 'workflow_call:' "$project_root/.github/workflows/ci.yml"
if grep -Fq "tags: ['v*']" "$release_workflow"; then
  print -u2 -- "release workflow still trusts a tag-supplied workflow definition"
  exit 1
fi
grep -Fq 'needs: [provenance, validate]' "$release_workflow"
grep -Fq 'uses: ./.github/workflows/ci.yml' "$release_workflow"
grep -Fq 'environment: release' "$release_workflow"
grep -Fq 'ref: main' "$release_workflow"
grep -Fq "git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' --depth=1" \
  "$release_workflow"
grep -Fq './Scripts/verify_release_provenance.sh "$GITHUB_SHA" refs/remotes/origin/main' \
  "$release_workflow"
grep -Fq 'name: Require main to remain at the release commit' "$release_workflow"
grep -Fq "'\${{ needs.provenance.outputs.release_sha }}'" "$release_workflow"
grep -Fq 'gh release view "$tag"' "$release_workflow"
grep -Fq 'gh release upload "$tag" "${assets[@]}" --clobber' "$release_workflow"
grep -Fq './Scripts/release_verify_asset_names.sh "$version" "${release_assets[@]}"' \
  "$release_workflow"
[[ "$(grep -Fc './Scripts/release_verify_asset_names.sh "$version" "${release_assets[@]}"' \
  "$release_workflow")" == 2 ]] \
  || { print -u2 -- "exact asset-set verification must cover draft and public releases"; exit 1; }
grep -Fq './Scripts/release_notes.sh "$version"' "$release_workflow"
grep -Fq -- '--notes-file "$release_notes"' "$release_workflow"
grep -Fq "if: steps.release_state.outputs.state == 'draft'" "$release_workflow"
grep -Fq 'gh release edit "$tag" --draft=false --prerelease=false --latest' "$release_workflow"
grep -Fq './Scripts/verify_release_artifacts.sh "$version" "$draft_directory"' \
  "$release_workflow"
grep -Fq './Scripts/verify_release_artifacts.sh "$version" "$public_directory"' \
  "$release_workflow"
grep -Fq 'releases/latest/download/appcast.xml' "$release_workflow"
grep -Fq -- '--retry-all-errors' "$release_workflow"
grep -Fq 'brew audit --cask --strict "$test_tap/cowlick"' "$release_workflow"
grep -Fq 'brew install --cask "$test_tap/cowlick"' "$release_workflow"
grep -Fq 'name: Capture Homebrew tap state' "$release_workflow"
grep -Fq 'name: Persist rollback snapshot' "$release_workflow"
grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
  "$release_workflow"
grep -Fq 'name: Verify canonical Homebrew installation' "$release_workflow"
grep -Fq "canonical_tap='henryvn27/cowlick'" "$release_workflow"
grep -Fq 'cmp Config/Homebrew/cowlick.rb "$tap_directory/Casks/cowlick.rb"' \
  "$release_workflow"
grep -Fq 'brew install --cask "$canonical_tap/cowlick"' "$release_workflow"
grep -Fq './Scripts/release_verify_app.sh /Applications/Cowlick.app' "$release_workflow"
grep -Fq 'timeout-minutes: 120' "$release_workflow"
grep -Fq 'contents: read' "$release_workflow"
if grep -Fq 'git merge-base --is-ancestor HEAD origin/main' "$release_workflow"; then
  print -u2 -- "release workflow still permits a stale main ancestor"
  exit 1
fi
publish_line="$(grep -n 'name: Publish verified GitHub release' "$release_workflow" | cut -d: -f1)"
draft_asset_verify_line="$(grep -nF './Scripts/release_verify_asset_names.sh "$version"' "$release_workflow" | head -n 1 | cut -d: -f1)"
public_asset_verify_line="$(grep -nF './Scripts/release_verify_asset_names.sh "$version"' "$release_workflow" | tail -n 1 | cut -d: -f1)"
public_verify_line="$(grep -n 'name: Verify public downloads' "$release_workflow" | cut -d: -f1)"
homebrew_verify_line="$(grep -n 'name: Verify Homebrew cask and installation' "$release_workflow" | cut -d: -f1)"
homebrew_snapshot_line="$(grep -n 'name: Capture Homebrew tap state' "$release_workflow" | cut -d: -f1)"
rollback_snapshot_line="$(grep -n 'name: Persist rollback snapshot' "$release_workflow" | cut -d: -f1)"
homebrew_line="$(grep -n 'name: Update Homebrew tap' "$release_workflow" | cut -d: -f1)"
canonical_homebrew_line="$(grep -n 'name: Verify canonical Homebrew installation' "$release_workflow" | cut -d: -f1)"
release_rollback_line="$(grep -n 'rollback_release:' "$release_workflow" | cut -d: -f1)"
tap_rollback_line="$(grep -n 'rollback_tap:' "$release_workflow" | cut -d: -f1)"
main_recheck_line="$(grep -n 'name: Require main to remain at the release commit' "$release_workflow" | cut -d: -f1)"
tag_line="$(grep -n 'name: Create or verify release tag' "$release_workflow" | cut -d: -f1)"
(( main_recheck_line < tag_line )) \
  || { print -u2 -- "main provenance is not rechecked before tag mutation"; exit 1; }
(( draft_asset_verify_line < homebrew_snapshot_line \
  && homebrew_snapshot_line < rollback_snapshot_line \
  && rollback_snapshot_line < publish_line \
  && publish_line < public_verify_line \
  && public_verify_line < public_asset_verify_line \
  && public_verify_line < homebrew_verify_line \
  && homebrew_verify_line < homebrew_line \
  && homebrew_line < canonical_homebrew_line \
  && canonical_homebrew_line < release_rollback_line \
  && release_rollback_line < tap_rollback_line )) \
  || { print -u2 -- "release publication steps are out of order"; exit 1; }
if grep -Fq 'if: ${{ failure() }}' "$release_workflow"; then
  print -u2 -- "release rollback still depends on same-job failure state"
  exit 1
fi
grep -Fq -- '--draft=true --latest=false' "$release_workflow"
rollback_condition="if: \${{ always() && (needs.release.result == 'failure' || needs.release.result == 'cancelled') }}"
[[ "$(grep -Fc "$rollback_condition" "$release_workflow")" == 2 ]] \
  || { print -u2 -- "release and tap rollback jobs are not independently conditional"; exit 1; }
[[ "$(grep -Fc 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' \
  "$release_workflow")" == 2 ]] \
  || { print -u2 -- "each rollback job must download the durable snapshot"; exit 1; }
[[ "$(grep -Fc 'name: Require durable rollback snapshot' "$release_workflow")" == 2 ]] \
  || { print -u2 -- "each rollback job must require its durable snapshot"; exit 1; }
grep -Fq 'name: Restore failed or cancelled GitHub release state' "$release_workflow"
grep -Fq 'name: Restore failed or cancelled Homebrew tap state' "$release_workflow"
grep -Fq 'timeout-minutes: 6' "$release_workflow"
grep -Fq 'timeout-minutes: 8' "$release_workflow"
if grep -Eq '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' "$release_workflow"; then
  print -u2 -- "release workflow uses a shell builtin unavailable in macOS Bash 3.2"
  exit 1
fi
grep -Fq 'TAP_PUBLISHED_CONTENT_SHA: ${{ needs.release.outputs.tap_published_content_sha }}' \
  "$release_workflow"
grep -Fq 'TAP_PUBLISHED_COMMIT_SHA: ${{ needs.release.outputs.tap_published_commit_sha }}' \
  "$release_workflow"
grep -Fq 'published_content_sha=%s' "$release_workflow"
grep -Fq 'published_commit_sha=%s' "$release_workflow"
grep -Fq '"$latest_commit_sha" == "$published_commit_sha"' "$tap_rollback_guard"
grep -Fq 'Homebrew tap no longer matches this run publication' "$tap_rollback_guard"
grep -Fq './Scripts/release_tap_rollback_guard.sh' "$release_workflow"
grep -Fq 'Restore Cowlick cask after failed release' "$release_workflow"
grep -Fq 'Remove Cowlick cask after failed release' "$release_workflow"
grep -Fq 'refusing to overwrite it' "$tap_rollback_guard"
grep -Fq 'release_restored=true' "$release_workflow"
grep -Fq "trap '' HUP INT TERM" "$mutation_runner"
grep -Fq "kill 9, shift" "$mutation_runner"
grep -Fq './Scripts/release_run_mutation.sh' "$release_workflow"
grep -Fq './Scripts/release_stability_guard.sh' "$release_workflow"
grep -Fq 'tap_observation="$current_state|$current_sha|$latest_commit_sha|$latest_commit_message"' \
  "$release_workflow"
grep -Fq 'required_count' "$stability_guard"
publication_marker_line="$(grep -nF 'publication_message="Update Cowlick to $RELEASE_VERSION' "$release_workflow" | head -n 1 | cut -d: -f1)"
[[ "$(grep -Fc 'publication_message="Update Cowlick to $RELEASE_VERSION' \
  "$release_workflow")" == 2 ]] \
  || { print -u2 -- "tap publication and rollback do not share the run marker"; exit 1; }
tap_put_line="$(grep -nF '> "$snapshot/update-response"' "$release_workflow" | cut -d: -f1)"
published_output_line="$(grep -nF "printf 'published_commit_sha=%s" "$release_workflow" | cut -d: -f1)"
[[ -n "$publication_marker_line" && -n "$tap_put_line" && -n "$published_output_line" \
  && "$publication_marker_line" -lt "$tap_put_line" \
  && "$tap_put_line" -lt "$published_output_line" ]] \
  || { print -u2 -- "tap publication identity is not recorded around mutation"; exit 1; }
if grep -A8 -F 'state=published' "$release_workflow" | grep -Fq -- '--clobber'; then
  print -u2 -- "published release path can overwrite assets"
  exit 1
fi

for required_check in \
  'com.henryvn27.Cowlick' \
  'TeamIdentifier=' \
  'flags=.*runtime' \
  'appcast enclosure URL is incorrect' \
  'appcast enclosure length is incorrect' \
  'appcast build version is incorrect' \
  'appcast marketing version is incorrect' \
  'appcast archive signature is missing' \
  '--verify --ed-key-file - "$appcast"' \
  '--verify --ed-key-file - "$zip" "$enclosure_signature"' \
  'ZIP and DMG contain different Cowlick.app builds'; do
  grep -Fq -- "$required_check" "$artifact_verifier" "$script_dir/release_common.sh" \
    || { print -u2 -- "release verifier omitted: $required_check"; exit 1; }
done

repository="$temporary_directory/provenance"
git init -q -b main "$repository"
git -C "$repository" config user.name Cowlick
git -C "$repository" config user.email cowlick@example.invalid
print -n -- first > "$repository/release.txt"
git -C "$repository" add release.txt
git -C "$repository" commit -qm first
first_commit="$(git -C "$repository" rev-parse HEAD)"
git -C "$repository" update-ref refs/remotes/origin/main HEAD
(cd "$repository" && "$provenance_script" HEAD refs/remotes/origin/main >/dev/null)

print -n -- second > "$repository/release.txt"
git -C "$repository" commit -qam second
git -C "$repository" update-ref refs/remotes/origin/main HEAD
git -C "$repository" checkout -q --detach "$first_commit"
if (cd "$repository" && "$provenance_script" HEAD refs/remotes/origin/main >/dev/null 2>&1); then
  print -u2 -- "stale release commit unexpectedly matched current main"
  exit 1
fi

git -C "$repository" checkout -q -b divergent "$first_commit"
print -n -- divergent > "$repository/release.txt"
git -C "$repository" commit -qam divergent
if (cd "$repository" && "$provenance_script" HEAD refs/remotes/origin/main >/dev/null 2>&1); then
  print -u2 -- "divergent release commit unexpectedly matched current main"
  exit 1
fi

git -C "$repository" checkout -q main
(cd "$repository" && "$provenance_script" HEAD refs/remotes/origin/main >/dev/null)
git -C "$repository" update-ref -d refs/remotes/origin/main
if (cd "$repository" && "$provenance_script" HEAD refs/remotes/origin/main >/dev/null 2>&1); then
  print -u2 -- "release commit unexpectedly matched a missing main ref"
  exit 1
fi

print "Release script tests passed."
