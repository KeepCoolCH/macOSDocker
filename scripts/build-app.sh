#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -project "$ROOT/macOSDocker.xcodeproj" -scheme macOSDocker -configuration Release -derivedDataPath "$ROOT/build/ReleaseDerivedData" -allowProvisioningUpdates build
APP="$ROOT/build/ReleaseDerivedData/Build/Products/Release/macOSDocker.app"
codesign --verify --deep --strict "$APP"
printf '\nApp: %s\n' "$APP"
