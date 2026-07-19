#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "$script_dir/release_common.sh"

version="${1:-1.0.0}"
mode="${2:---source-only}"
[[ "$mode" == "--source-only" || "$mode" == "--distribution" ]] \
  || release_error "usage: release_preflight.sh VERSION [--source-only|--distribution]"

validate_release_version "$version"
validate_project_version "$project_root" "$version"

for command_name in xcodebuild xcodegen codesign hdiutil ditto shasum ruby; do
  require_release_command "$command_name"
done

[[ -f "$project_root/Config/Info.plist" ]] || release_error "Config/Info.plist is missing"
[[ -f "$project_root/Config/ExportOptions.plist" ]] \
  || release_error "Config/ExportOptions.plist is missing"
[[ -f "$project_root/Config/Homebrew/cowlick.rb.template" ]] \
  || release_error "Cowlick Homebrew cask template is missing"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_root/Config/Info.plist")"
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$project_root/Config/Info.plist")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$project_root/Config/Info.plist")"
requires_signed_feed="$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$project_root/Config/Info.plist")"
export_method="$(/usr/libexec/PlistBuddy -c 'Print :method' "$project_root/Config/ExportOptions.plist")"
export_signing_style="$(/usr/libexec/PlistBuddy -c 'Print :signingStyle' "$project_root/Config/ExportOptions.plist")"
[[ "$bundle_identifier" == '$(PRODUCT_BUNDLE_IDENTIFIER)' ]] \
  || release_error "Info.plist must inherit PRODUCT_BUNDLE_IDENTIFIER"
[[ "$feed_url" == "https://github.com/henryvn27/cowlick/releases/latest/download/appcast.xml" ]] \
  || release_error "Sparkle feed URL does not point to the Cowlick release feed"
[[ -n "$public_key" ]] || release_error "Sparkle public key is empty"
[[ "$requires_signed_feed" == "true" ]] || release_error "Sparkle signed feeds are not required"
[[ "$export_method" == "developer-id" ]] \
  || release_error "release export method must be developer-id"
[[ "$export_signing_style" == "manual" ]] \
  || release_error "release export signing must be manual"

if [[ "$mode" == "--distribution" ]]; then
  for command_name in security swift xcrun spctl lipo xmllint; do
    require_release_command "$command_name"
  done

  missing=()
  for variable_name in DEVELOPER_ID_APPLICATION DEVELOPMENT_TEAM NOTARYTOOL_PROFILE SPARKLE_PRIVATE_KEY; do
    [[ -n "${(P)variable_name:-}" ]] || missing+=("$variable_name")
  done
  (( ${#missing} == 0 )) \
    || release_error "missing release environment: ${(j:, :)missing}"

  grep -Eq "^## ${version//./\\.}([[:space:]]|$)" "$project_root/CHANGELOG.md" \
    || release_error "CHANGELOG.md has no release section for $version"

  security find-identity -v -p codesigning | grep -Fq -- "\"$DEVELOPER_ID_APPLICATION\"" \
    || release_error "Developer ID Application identity is not available in the active keychain"

  derived_public_key="$(COWLICK_SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY" swift -e '
    import CryptoKit
    import Foundation

    let value = ProcessInfo.processInfo.environment["COWLICK_SPARKLE_PRIVATE_KEY"]!
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: value) else { exit(2) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    print(key.publicKey.rawRepresentation.base64EncodedString())
  ')" || release_error "SPARKLE_PRIVATE_KEY is not a valid Ed25519 private key"
  [[ "$derived_public_key" == "$public_key" ]] \
    || release_error "Sparkle private key does not match the public key embedded in the app"
fi

print "Cowlick $version release preflight passed ($mode)."
