#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

xcrun swift "$root_dir/Scripts/capture_launch_assets.swift" --self-check
xcrun swift "$root_dir/Scripts/validate_launch_assets.swift" --self-check
grep -Fq 'process.arguments = ["--require-clean", sourceCommit]' \
  "$root_dir/Scripts/validate_launch_assets.swift"

digest_script="$root_dir/Scripts/product_source_digest.sh"
digest_repository="$temporary_directory/digest-repository"
git init -q -b captured "$digest_repository"
git -C "$digest_repository" config user.name Cowlick
git -C "$digest_repository" config user.email cowlick@example.invalid
mkdir -p \
  "$digest_repository/Cowlick" \
  "$digest_repository/CowlickHook" \
  "$digest_repository/Config" \
  "$digest_repository/Cowlick.xcodeproj" \
  "$digest_repository/Assets"
printf 'app source\n' > "$digest_repository/Cowlick/App.swift"
printf 'hook source\n' > "$digest_repository/CowlickHook/main.swift"
printf 'config\n' > "$digest_repository/Config/Info.plist"
printf 'project\n' > "$digest_repository/project.yml"
printf 'packages\n' > "$digest_repository/Package.resolved"
printf 'pbx\n' > "$digest_repository/Cowlick.xcodeproj/project.pbxproj"
printf 'asset one\n' > "$digest_repository/Assets/demo.txt"
git -C "$digest_repository" add .
git -C "$digest_repository" commit -qm captured
captured_digest="$("$digest_script" --repository "$digest_repository" HEAD)"
[[ "$captured_digest" =~ ^[0-9a-f]{64}$ ]]

printf 'asset two\n' >> "$digest_repository/Assets/demo.txt"
git -C "$digest_repository" add Assets/demo.txt
git -C "$digest_repository" commit -qm assets-only
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" == "$captured_digest" ]]

git -C "$digest_repository" checkout -q --orphan rebased
git -C "$digest_repository" commit -qm rebased
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" == "$captured_digest" ]]

printf 'changed\n' >> "$digest_repository/Cowlick/App.swift"
git -C "$digest_repository" add Cowlick/App.swift
git -C "$digest_repository" commit -qm changed-content
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" != "$captured_digest" ]]
git -C "$digest_repository" revert --no-edit HEAD >/dev/null
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" == "$captured_digest" ]]

chmod +x "$digest_repository/Cowlick/App.swift"
git -C "$digest_repository" add Cowlick/App.swift
git -C "$digest_repository" commit -qm changed-mode
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" != "$captured_digest" ]]
git -C "$digest_repository" revert --no-edit HEAD >/dev/null

git -C "$digest_repository" mv Cowlick/App.swift Cowlick/Renamed.swift
git -C "$digest_repository" commit -qm changed-path
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" != "$captured_digest" ]]
git -C "$digest_repository" revert --no-edit HEAD >/dev/null

printf 'added\n' > "$digest_repository/Cowlick/Added.swift"
git -C "$digest_repository" add Cowlick/Added.swift
git -C "$digest_repository" commit -qm added-product-source
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" != "$captured_digest" ]]
git -C "$digest_repository" revert --no-edit HEAD >/dev/null

git -C "$digest_repository" rm -q CowlickHook/main.swift
git -C "$digest_repository" commit -qm deleted-product-source
deleted_digest="$(
  "$digest_script" --repository "$digest_repository" HEAD 2>/dev/null || true
)"
[[ "$deleted_digest" != "$captured_digest" ]]
git -C "$digest_repository" revert --no-edit HEAD >/dev/null
[[ "$("$digest_script" --repository "$digest_repository" HEAD)" == "$captured_digest" ]]

printf 'uncommitted asset\n' >> "$digest_repository/Assets/demo.txt"
[[ "$(
  "$digest_script" --repository "$digest_repository" --require-clean HEAD
)" == "$captured_digest" ]]

for dirty_state in unstaged staged untracked; do
  dirty_repository="$temporary_directory/digest-$dirty_state"
  git clone -q "$digest_repository" "$dirty_repository"
  case "$dirty_state" in
    unstaged) printf 'dirty\n' >> "$dirty_repository/Cowlick/App.swift" ;;
    staged)
      printf 'dirty\n' >> "$dirty_repository/Cowlick/App.swift"
      git -C "$dirty_repository" add Cowlick/App.swift
      ;;
    untracked) printf 'dirty\n' > "$dirty_repository/Cowlick/Untracked.swift" ;;
  esac
  if "$digest_script" --repository "$dirty_repository" --require-clean HEAD \
    >/dev/null 2>&1
  then
    echo "Product-source digest accepted $dirty_state capture input." >&2
    exit 1
  fi
done

app="$temporary_directory/Cowlick.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
printf 'app executable' > "$app/Contents/MacOS/Cowlick"
printf 'helper executable' > "$app/Contents/Helpers/cowlick-hook"
git -C "$root_dir" rev-parse HEAD > "$app/Contents/Resources/cowlick-source-commit.txt"
chmod +x "$app/Contents/MacOS/Cowlick" "$app/Contents/Helpers/cowlick-hook"
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.henryvn27.Cowlick "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0.0 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"

provenance="$temporary_directory/capture-provenance.json"
"$root_dir/Scripts/record_launch_asset_provenance.sh" \
  --app "$app" --source-ref HEAD --output "$provenance" >/dev/null
grep -Fq "\"sourceCommit\": \"$(git -C "$root_dir" rev-parse HEAD)\"" "$provenance"
grep -Fq '"productSourceAlgorithm": "sha256(git-ls-tree-r-z-full-tree-v1)"' "$provenance"
grep -Eq '"productSourceSHA256": "[0-9a-f]{64}"' "$provenance"
grep -Fq '"bundleIdentifier": "com.henryvn27.Cowlick"' "$provenance"
grep -Fq '"marketingVersion": "1.0.0"' "$provenance"
grep -Fq '"buildVersion": "1"' "$provenance"
grep -Eq '"appExecutableSHA256": "[0-9a-f]{64}"' "$provenance"
grep -Eq '"helperExecutableSHA256": "[0-9a-f]{64}"' "$provenance"

if "$root_dir/Scripts/record_launch_asset_provenance.sh" \
  --app "$app" --source-ref does-not-exist --output "$provenance" >/dev/null 2>&1
then
  echo "Unknown provenance source ref was accepted." >&2
  exit 1
fi

printf '%040d\n' 0 > "$app/Contents/Resources/cowlick-source-commit.txt"
if "$root_dir/Scripts/record_launch_asset_provenance.sh" \
  --app "$app" --source-ref HEAD --output "$provenance" >/dev/null 2>&1
then
  echo "Mismatched app source identity was accepted." >&2
  exit 1
fi
