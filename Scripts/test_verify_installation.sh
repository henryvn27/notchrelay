#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
temporary_directory="$(mktemp -d "${TMPDIR%/}/cowlick-verify-installation-tests.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

test_home="$temporary_directory/home"
app="$test_home/Applications/Cowlick.app"
helper="$app/Contents/Helpers/cowlick-hook"
shim="$test_home/.local/bin/cowlick-hook"
installed_helper="$test_home/Library/Application Support/Cowlick/bin/cowlick-hook"
fake_bin="$temporary_directory/bin"
source_identity="$app/Contents/Resources/cowlick-source-commit.txt"
source_commit='0123456789abcdef0123456789abcdef01234567'
mkdir -p "${helper:h}" "${shim:h}" "${installed_helper:h}" "${source_identity:h}" "$fake_bin"

print -r -- '#!/bin/zsh' > "$fake_bin/codesign"
print -r -- 'exit 0' >> "$fake_bin/codesign"
chmod 755 "$fake_bin/codesign"
print -r -- '#!/bin/zsh' > "$fake_bin/swift"
print -r -- 'print healthy' >> "$fake_bin/swift"
chmod 755 "$fake_bin/swift"

print -r -- '#!/bin/zsh' > "$helper"
print -r -- 'case "${1:-}" in' >> "$helper"
print -r -- '  version) print "Cowlick hook 1.0.0" ;;' >> "$helper"
print -r -- '  ping)' >> "$helper"
print -r -- '    case "${COWLICK_TEST_PING_MODE:-healthy}" in' >> "$helper"
print -r -- '      healthy) print '\''{"ok":true,"pid":1,"sourceCommit":"0123456789abcdef0123456789abcdef01234567","socket":"reachable"}'\'' ;;' >> "$helper"
print -r -- '      unhealthy) print '\''{"ok":false,"error":"app unavailable"}'\''; exit 1 ;;' >> "$helper"
print -r -- '      false-success) print '\''{"ok":false,"error":"app unavailable"}'\'' ;;' >> "$helper"
print -r -- '      malformed) print '\''not-json'\'' ;;' >> "$helper"
print -r -- '      *) exit 2 ;;' >> "$helper"
print -r -- '    esac ;;' >> "$helper"
print -r -- '  *) exit 2 ;;' >> "$helper"
print -r -- 'esac' >> "$helper"
chmod 755 "$helper"
cp "$helper" "$installed_helper"
ln -s "$installed_helper" "$shim"
print -r -- "$source_commit" > "$source_identity"

print -r -- '<?xml version="1.0" encoding="UTF-8"?>' > "$app/Contents/Info.plist"
print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> "$app/Contents/Info.plist"
print -r -- '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.henryvn27.Cowlick</string></dict></plist>' >> "$app/Contents/Info.plist"

env PATH="$fake_bin:$PATH" HOME="$test_home" \
  "$script_dir/verify_installation.sh" --app "$app" --development >/dev/null
env PATH="$fake_bin:$PATH" HOME="$test_home" \
  "$script_dir/verify_installation.sh" --app "$app" --development --installed \
    --source-commit "$source_commit" >/dev/null

for mode in unhealthy false-success malformed; do
  if env PATH="$fake_bin:$PATH" HOME="$test_home" COWLICK_TEST_PING_MODE="$mode" \
    "$script_dir/verify_installation.sh" --app "$app" --development >/dev/null 2>&1; then
    print -u2 "verify_installation accepted an invalid bridge result: $mode"
    exit 1
  fi
done

if env PATH="$fake_bin:$PATH" HOME="$test_home" \
  "$script_dir/verify_installation.sh" --app "$app" --development \
    --source-commit 'ffffffffffffffffffffffffffffffffffffffff' >/dev/null 2>&1; then
  print -u2 "verify_installation accepted a mismatched source identity"
  exit 1
fi

print -r -- '# changed' >> "$installed_helper"
if env PATH="$fake_bin:$PATH" HOME="$test_home" \
  "$script_dir/verify_installation.sh" --app "$app" --development --installed \
    --source-commit "$source_commit" >/dev/null 2>&1; then
  print -u2 "verify_installation accepted a mismatched installed helper"
  exit 1
fi
cp "$helper" "$installed_helper"

rm "$shim"
ln -s "$helper" "$shim"
if env PATH="$fake_bin:$PATH" HOME="$test_home" \
  "$script_dir/verify_installation.sh" --app "$app" --development --installed \
    --source-commit "$source_commit" >/dev/null 2>&1; then
  print -u2 "verify_installation accepted an unexpected helper shim target"
  exit 1
fi

print "Installation verifier health tests passed."
