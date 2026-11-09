#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE=${1:-${MACOSDOCKER_NOTARY_PROFILE:-}}
if [ -z "$PROFILE" ]; then
    echo 'Notarisierungsprofil angeben: scripts/release-app.sh PROFILNAME' >&2
    echo 'Für den Xcode-Ablauf stattdessen App archivieren.command öffnen.' >&2
    exit 2
fi
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
"$ROOT/scripts/archive-app.sh"
ARCHIVE="$ROOT/build/Distribution/macOSDocker.xcarchive"
EXPORT="$ROOT/build/Distribution/Export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$ROOT/scripts/DeveloperID-ExportOptions.plist" -exportPath "$EXPORT" -allowProvisioningUpdates
APP="$EXPORT/macOSDocker.app"
IDENTITY='Developer ID Application: Kevin Tobler (RYPSKH8HG5)'
for TOOL in "$APP/Contents/Resources/DockerTools/bin/macosdocker-cli" "$APP/Contents/Resources/DockerTools/bin/docker" "$APP/Contents/Resources/DockerTools/cli-plugins/docker-compose" "$APP/Contents/Resources/DockerTools/cli-plugins/docker-buildx"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$TOOL"
done
codesign --force --options runtime --timestamp --preserve-metadata=entitlements,requirements,identifier --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
ZIP="$ROOT/build/Distribution/macOSDocker.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format plist > "$ROOT/build/Distribution/notarization.plist"
STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$ROOT/build/Distribution/notarization.plist")
if [ "$STATUS" != 'Accepted' ]; then
    echo 'Notarisierung abgelehnt. Details: build/Distribution/notarization.plist' >&2
    exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
open -R "$ZIP"
printf '\nSigniert und notarisiert: %s\n' "$ZIP"
