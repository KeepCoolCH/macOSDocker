#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${KERNEL_VERSION:-7.3.1}
OUTPUT=${1:-"$ROOT/build/linux-kernel-$VERSION"}
JOBS=${KERNEL_JOBS:-4}
CONFIG=${KERNEL_CONFIG:-"$ROOT/guest/kernel.config"}
case "$VERSION" in *[!0-9.]*|'') exit 2;; esac
case "$JOBS" in *[!0-9]*|'') exit 2;; esac
mkdir -p "$OUTPUT"
OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd)
CONTAINER=$(docker create --platform linux/arm64 debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 sleep infinity)
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT
docker start "$CONTAINER" >/dev/null
docker cp "$CONFIG" "$CONTAINER:/kernel.config"
docker exec -e KERNEL_VERSION="$VERSION" -e KERNEL_JOBS="$JOBS" "$CONTAINER" sh -ec '
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential bc bison flex perl libssl-dev libelf-dev xz-utils curl ca-certificates kmod
mkdir -p /kernel /output /modules
cd /kernel
major=${KERNEL_VERSION%%.*}
curl -fL --retry 3 -o linux.tar.xz "https://cdn.kernel.org/pub/linux/kernel/v$major.x/linux-$KERNEL_VERSION.tar.xz"
curl -fL --retry 3 -o sha256sums.asc "https://cdn.kernel.org/pub/linux/kernel/v$major.x/sha256sums.asc"
sed -n "s/^\\([0-9a-f]\\{64\\}\\)  linux-$KERNEL_VERSION.tar.xz$/\\1  linux.tar.xz/p" sha256sums.asc > expected.sha256
test -s expected.sha256
sha256sum -c expected.sha256
tar -xf linux.tar.xz
cd "linux-$KERNEL_VERSION"
cp /kernel.config .config
scripts/config --set-str LOCALVERSION "-macosdocker" --disable LOCALVERSION_AUTO --set-str MODULE_SIG_KEY certs/signing_key.pem --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
make olddefconfig
make -j"$KERNEL_JOBS" Image modules
make INSTALL_MOD_PATH=/modules modules_install
release=$(make -s kernelrelease)
cp arch/arm64/boot/Image /output/vmlinuz
cp .config /output/kernel.config
printf "%s\n" "$release" > /output/kernel-version
cp /kernel/expected.sha256 /output/kernel-source.sha256
tar -C /modules -czf /output/modules.tar.gz lib/modules
'
docker cp "$CONTAINER:/output/." "$OUTPUT/"
KERNEL_IMAGE_DIR="$OUTPUT" "$ROOT/scripts/build-minimal-linux.sh" "$OUTPUT"
