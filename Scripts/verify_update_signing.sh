#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
app="${1:-$project_root/DerivedData/Build/Products/Release/Cowlick.app}"
[[ -d "$app" ]] || { print -u2 "Release app not found: $app"; exit 1; }

proof_directory="$(mktemp -d "${TMPDIR%/}/cowlick-update-proof.XXXXXX")"
chmod 700 "$proof_directory"
trap 'rm -rf "$proof_directory"' EXIT

KEY_PATH="$proof_directory/private-key" PUB_PATH="$proof_directory/public-key" swift -e '
  import CryptoKit
  import Foundation

  let key = Curve25519.Signing.PrivateKey()
  let environment = ProcessInfo.processInfo.environment
  try Data(key.rawRepresentation.base64EncodedString().utf8).write(
    to: URL(fileURLWithPath: environment["KEY_PATH"]!), options: .atomic)
  try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(
    to: URL(fileURLWithPath: environment["PUB_PATH"]!), options: .atomic)
'
chmod 600 "$proof_directory/private-key"

ditto "$app" "$proof_directory/Cowlick.app"
public_key="$(/bin/cat "$proof_directory/public-key")"
/usr/libexec/PlistBuddy \
  -c "Set :SUPublicEDKey $public_key" \
  "$proof_directory/Cowlick.app/Contents/Info.plist"
codesign --force --deep --sign - "$proof_directory/Cowlick.app" >/dev/null

artifact_directory="$proof_directory/artifacts"
mkdir -p "$artifact_directory"
ditto -c -k --sequesterRsrc --keepParent \
  "$proof_directory/Cowlick.app" \
  "$artifact_directory/Cowlick-1.0.0.zip"

private_key="$(/bin/cat "$proof_directory/private-key")"
SPARKLE_PRIVATE_KEY="$private_key" \
  "$script_dir/generate_appcast.sh" "$artifact_directory" 1.0.0

sign_tool="$project_root/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_tool" ]] || { print -u2 "Sparkle sign_update tool not found."; exit 1; }
"$sign_tool" \
  --verify \
  --ed-key-file "$proof_directory/private-key" \
  "$artifact_directory/appcast.xml"
archive_signature="$(xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
  "$artifact_directory/appcast.xml")"
[[ -n "$archive_signature" ]] || { print -u2 "Archive signature was not emitted."; exit 1; }
"$sign_tool" \
  --verify \
  --ed-key-file "$proof_directory/private-key" \
  "$artifact_directory/Cowlick-1.0.0.zip" \
  "$archive_signature"
xmllint --noout "$artifact_directory/appcast.xml"

print "Sparkle archive and signed-feed verification passed."
