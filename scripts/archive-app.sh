#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARCHIVE="$ROOT/build/Distribution/macOSDocker.xcarchive"
mkdir -p "$ROOT/build/Distribution"
xcodebuild -project "$ROOT/macOSDocker.xcodeproj" -scheme macOSDocker -configuration Release -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/build/DistributionDerivedData" -allowProvisioningUpdates -allowProvisioningDeviceRegistration archive
codesign --verify --deep --strict "$ARCHIVE/Products/Applications/macOSDocker.app"
if [ "${1:-}" = "--organizer" ]; then
    open "$ARCHIVE"
fi
printf '\nArchiv: %s\n' "$ARCHIVE"
