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

print "Release script tests passed."
