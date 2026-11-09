#!/bin/sh
set -eu
ROOT=${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
CACHE="$ROOT/build/tool-downloads"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DockerTools"
mkdir -p "$CACHE" "$DEST/bin" "$DEST/cli-plugins" "$DEST/licenses"
fetch() {
    NAME=$1 URL=$2 HASH=$3
    if [ ! -f "$CACHE/$NAME" ]; then
        curl -fsSL --retry 3 "$URL" -o "$CACHE/$NAME.partial"
        mv "$CACHE/$NAME.partial" "$CACHE/$NAME"
    fi
    printf '%s  %s\n' "$HASH" "$CACHE/$NAME" | shasum -a 256 -c -
}
fetch docker-29.9.3.tgz https://download.docker.com/mac/static/stable/aarch64/docker-29.9.3.tgz 79145e169bca0b9571d02de8e1cd311a36e0e8fdb4599b6661a87b1bb3afbe13
fetch docker-compose https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-darwin-aarch64 998735c9b6fe68a4f05895e6ea73d71ad06f9fc7046383ad89e47346781b6af5
fetch docker-buildx https://github.com/docker/buildx/releases/download/v0.37.0/buildx-v0.37.0.darwin-arm64 4cf78bb790f96f576522af0db716c7c25e8937a71c3303a165ff90d5105170ff
TEMP=$(mktemp -d "$CACHE/extract.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
tar -xzf "$CACHE/docker-29.9.3.tgz" -C "$TEMP" docker/docker
cp "$TEMP/docker/docker" "$DEST/bin/docker"
cp "$CACHE/docker-compose" "$DEST/cli-plugins/docker-compose"
cp "$CACHE/docker-buildx" "$DEST/cli-plugins/docker-buildx"
xcrun swiftc -O -target "$(uname -m)-apple-macos${MACOSX_DEPLOYMENT_TARGET:-14.0}" "$ROOT/macOSDocker/Models.swift" "$ROOT/macOSDocker/CommandParser.swift" "$ROOT/macOSDocker/TerminalMountProtocol.swift" "$ROOT/vendor/TerminalMountClient.swift" -o "$DEST/bin/macosdocker-cli"
for TOOL in "$DEST/bin/docker" "$DEST/bin/macosdocker-cli" "$DEST/cli-plugins/docker-compose" "$DEST/cli-plugins/docker-buildx"; do
    chmod 755 "$TOOL"
    if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
        codesign --force --sign - "$TOOL"
    else
        SIGNING_IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}
        case "$SIGNING_IDENTITY" in
            ""|-) echo 'Eine gültige Apple-Signieridentität für die eingebetteten Docker-Werkzeuge fehlt.' >&2; exit 1 ;;
        esac
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$TOOL"
    fi
done
cp "$ROOT"/vendor/docker-tools/* "$DEST/licenses/"
IMAGE="$ROOT/build/linux"
[ -f "$IMAGE/system.raw" ] || { echo 'Basisimage fehlt: scripts/build-linux.sh zuerst ausführen.' >&2; exit 1; }
if [ ! -f "$IMAGE/system.raw.gz" ] || [ "$IMAGE/system.raw" -nt "$IMAGE/system.raw.gz" ]; then
    gzip -c "$IMAGE/system.raw" > "$IMAGE/system.raw.gz.partial"
    mv "$IMAGE/system.raw.gz.partial" "$IMAGE/system.raw.gz"
fi
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LinuxImage"
cp "$IMAGE/vmlinuz" "$IMAGE/initramfs" "$IMAGE/system.raw.gz" "$IMAGE/packages.txt" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LinuxImage/"

if [ -f "$IMAGE/kernel-version" ]; then
    cp "$IMAGE/kernel-version" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LinuxImage/"
fi
