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
grep -Fq 'derived_data="$project_root/DerivedData"' "$package_script"
grep -Fq -- '-derivedDataPath "$derived_data"' "$package_script"
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
grep -Fq 'gh release view "$tag"' "$release_workflow"
grep -Fq 'gh release upload "$tag" "${assets[@]}" --clobber' "$release_workflow"
grep -Fq "if: steps.release_state.outputs.state == 'draft'" "$release_workflow"
grep -Fq 'gh release edit "$tag" --draft=false --prerelease=false --latest' "$release_workflow"
grep -Fq './Scripts/verify_release_artifacts.sh "$version" "$draft_directory"' \
  "$release_workflow"
grep -Fq './Scripts/verify_release_artifacts.sh "$version" "$public_directory"' \
  "$release_workflow"
grep -Fq 'releases/latest/download/appcast.xml' "$release_workflow"
grep -Fq 'brew audit --cask --strict "$test_tap/cowlick"' "$release_workflow"
grep -Fq 'brew install --cask "$test_tap/cowlick"' "$release_workflow"
grep -Fq 'cmp -s Config/Homebrew/cowlick.rb "$existing_cask"' "$release_workflow"
grep -Fq 'lipo -verify_arch arm64 x86_64 "$app/Contents/Helpers/cowlick-hook"' \
  "$release_workflow"
grep -Fq 'contents: read' "$release_workflow"
if grep -Fq 'git merge-base --is-ancestor HEAD origin/main' "$release_workflow"; then
  print -u2 -- "release workflow still permits a stale main ancestor"
  exit 1
fi
publish_line="$(grep -n 'name: Publish verified GitHub release' "$release_workflow" | cut -d: -f1)"
public_verify_line="$(grep -n 'name: Verify public downloads' "$release_workflow" | cut -d: -f1)"
homebrew_verify_line="$(grep -n 'name: Verify Homebrew cask and installation' "$release_workflow" | cut -d: -f1)"
homebrew_line="$(grep -n 'name: Update Homebrew tap' "$release_workflow" | cut -d: -f1)"
(( publish_line < public_verify_line \
  && public_verify_line < homebrew_verify_line \
  && homebrew_verify_line < homebrew_line )) \
  || { print -u2 -- "release publication steps are out of order"; exit 1; }
[[ "$(tail -n +"$homebrew_line" "$release_workflow" | grep -c '^[[:space:]]*- name:')" == 1 ]] \
  || { print -u2 -- "Homebrew tap update is not the final release step"; exit 1; }
if grep -A8 -F 'state=published' "$release_workflow" | grep -Fq -- '--clobber'; then
  print -u2 -- "published release path can overwrite assets"
  exit 1
fi

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
