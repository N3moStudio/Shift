#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/package_helpers.py --check
python3 scripts/check_appearance.py
command -v xcodebuild >/dev/null || { echo "Xcode on macOS is required." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
app="build/DerivedData/Build/Products/Release-iphoneos/Locus.app"
test -d "$app/PlugIns/LocusActivity.appex" || { echo "Live Activity extension missing; refusing incomplete IPA." >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :NSSupportsLiveActivities' "$app/Info.plist" | /usr/bin/grep -qx true
test -s "$app/OpenSourceNotices.txt" || { echo "License notices missing; refusing incomplete IPA." >&2; exit 1; }
test -s "$app/Shift-Windows-Helper.zip" || { echo "Windows helper missing; refusing incomplete IPA." >&2; exit 1; }
test -s "$app/Shift-FindMy-Cloud.zip" || { echo "Cloud helper missing; refusing incomplete IPA." >&2; exit 1; }
# Preserve requested groups in ad-hoc signatures so SideStore can provision
# and rewrite them. These are placeholders, not distributable Apple signatures.
codesign --force --sign - --generate-entitlement-der \
  --entitlements LocusActivity/LocusActivity.entitlements "$app/PlugIns/LocusActivity.appex"
codesign --force --sign - --generate-entitlement-der \
  --entitlements Locus/Resources/Locus.entitlements "$app"
codesign --verify --deep --strict "$app"
stage="$(mktemp -d "$PWD/build/package.XXXXXX")"
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/Locus.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid app version for IPA filename: $version" >&2; exit 1; }
output="$PWD/build/Shift $version.ipa"
if [ -f "$output" ]; then rm "$output"; fi
(cd "$stage" && /usr/bin/zip -qry "$output" Payload)
python3 scripts/check_ipa_appearance.py "$output"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'ipa_path=%s\n' "$output" >> "$GITHUB_OUTPUT"
fi
echo "Created $output (ad-hoc placeholders; SideStore must sign it for your device)."
