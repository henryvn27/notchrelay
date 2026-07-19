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
