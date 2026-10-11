#!/bin/zsh
# Build a Developer ID signed, notarized Get.app and zip it for GitHub Releases.
#
#   Scripts/release.sh                  # archive, export, notarize, staple, zip
#   Scripts/release.sh --skip-notarize  # stop after the signed zip (local check)
#
# Notarization reads App Store Connect credentials from a notarytool keychain
# profile, "get-notary" by default (override with NOTARY_PROFILE). Create it once:
#   xcrun notarytool store-credentials get-notary --apple-id <id> --team-id AUCR797TMH
#
# Output in build/release/: Get.zip (the stable name, linked as
# https://github.com/v57/Get/releases/latest/download/Get.zip) and
# Get-<version>.zip. Publishing the release is a separate, manual step; the
# script prints the gh command.
set -euo pipefail

cd "$(dirname "$0")/.."
team=AUCR797TMH
profile=${NOTARY_PROFILE:-get-notary}
notarize=1
[[ ${1:-} == --skip-notarize ]] && notarize=0

out=build/release
rm -rf $out
mkdir -p $out

echo "Archiving…"
xcodebuild -project Get.xcodeproj -scheme Get -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $out/Get.xcarchive \
  DEVELOPMENT_TEAM=$team archive -quiet

cat > $out/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath $out/Get.xcarchive -exportPath $out/export \
  -exportOptionsPlist $out/export.plist -quiet

app=$out/export/Get.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $app/Contents/Info.plist)
codesign --verify --strict --deep $app
codesign -dv $app 2>&1 | grep -E 'Authority=Developer ID Application|flags=.*runtime' >/dev/null ||
  { echo "Not signed with Developer ID and the hardened runtime" >&2; exit 1; }

if (( notarize )); then
  echo "Notarizing $version…"
  ditto -c -k --keepParent $app $out/notarize.zip
  xcrun notarytool submit $out/notarize.zip --keychain-profile "$profile" --wait
  xcrun stapler staple $app
  spctl --assess --type execute -vv $app
fi

ditto -c -k --keepParent $app $out/Get.zip
cp $out/Get.zip $out/Get-$version.zip
rm -f $out/notarize.zip

echo
echo "Get $version: $(du -h $out/Get.zip | cut -f1) zipped, $(du -sh $app | cut -f1) app"
shasum -a 256 $out/Get.zip
(( notarize )) || echo "Not notarized (--skip-notarize): Gatekeeper will block this zip on other Macs."
echo "Publish (manual): gh release create v$version $out/Get.zip $out/Get-$version.zip --title \"Get $version\""
