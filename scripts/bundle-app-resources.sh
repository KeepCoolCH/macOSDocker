#!/bin/sh
set -eu
ROOT=${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
rm -rf "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/NetworkHelper"
rm -rf "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/vmnet-broker.xpc"
rmdir "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices" 2>/dev/null || true
"$ROOT/scripts/bundle-docker-tools.sh"
