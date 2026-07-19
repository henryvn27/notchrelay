#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "$script_dir/release_common.sh"

temporary_directory="$(mktemp -d "${TMPDIR%/}/cowlick-release-tests.XXXXXX")"
chmod 700 "$temporary_directory"
trap 'rm -rf "$temporary_directory"' EXIT

"$script_dir/release_preflight.sh" 1.0.0 --source-only >/dev/null

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

fake_dmg="$temporary_directory/Cowlick-1.0.0.dmg"
print -n -- 'cowlick-release-fixture' > "$fake_dmg"
cask="$temporary_directory/cowlick.rb"
"$script_dir/render_homebrew_cask.sh" 1.0.0 "$fake_dmg" "$cask" >/dev/null
expected_sha="$(shasum -a 256 "$fake_dmg" | awk '{print $1}')"
grep -q "version \"1.0.0\"" "$cask"
grep -q "sha256 \"$expected_sha\"" "$cask"
grep -q 'app "Cowlick.app"' "$cask"
if grep -q '__VERSION__\|__SHA256__\|NotchRelay\|notchrelay\|Forelock\|forelock' "$cask"; then
  print -u2 -- "rendered cask contains an unresolved or legacy product value"
  exit 1
fi

release_workflow="$project_root/.github/workflows/release.yml"
grep -Fq 'needs: provenance' "$release_workflow"
grep -Fq "git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' --depth=1" \
  "$release_workflow"
grep -Fq 'contents: read' "$release_workflow"
if grep -Fq 'git merge-base --is-ancestor HEAD origin/main' "$release_workflow"; then
  print -u2 -- "release workflow still permits a stale main ancestor"
  exit 1
fi

release_commit_matches_main() {
  local repository="$1"
  local head_sha main_sha
  head_sha="$(git -C "$repository" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  main_sha="$(git -C "$repository" rev-parse --verify \
    'refs/remotes/origin/main^{commit}' 2>/dev/null)" || return 1
  [[ "$head_sha" == "$main_sha" ]]
}

repository="$temporary_directory/provenance"
git init -q -b main "$repository"
git -C "$repository" config user.name Cowlick
git -C "$repository" config user.email cowlick@example.invalid
print -n -- first > "$repository/release.txt"
git -C "$repository" add release.txt
git -C "$repository" commit -qm first
first_commit="$(git -C "$repository" rev-parse HEAD)"
git -C "$repository" update-ref refs/remotes/origin/main HEAD
release_commit_matches_main "$repository"

print -n -- second > "$repository/release.txt"
git -C "$repository" commit -qam second
git -C "$repository" update-ref refs/remotes/origin/main HEAD
git -C "$repository" checkout -q --detach "$first_commit"
if release_commit_matches_main "$repository"; then
  print -u2 -- "stale release commit unexpectedly matched current main"
  exit 1
fi

git -C "$repository" checkout -q -b divergent "$first_commit"
print -n -- divergent > "$repository/release.txt"
git -C "$repository" commit -qam divergent
if release_commit_matches_main "$repository"; then
  print -u2 -- "divergent release commit unexpectedly matched current main"
  exit 1
fi

git -C "$repository" checkout -q main
release_commit_matches_main "$repository"
git -C "$repository" update-ref -d refs/remotes/origin/main
if release_commit_matches_main "$repository"; then
  print -u2 -- "release commit unexpectedly matched a missing main ref"
  exit 1
fi

print "Release script tests passed."
