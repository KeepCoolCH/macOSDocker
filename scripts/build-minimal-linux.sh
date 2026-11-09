#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-"$ROOT/build/linux-minimal"}
KERNEL=${KERNEL_IMAGE_DIR:-"$ROOT/build/linux"}
mkdir -p "$OUTPUT"
OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd)
KERNEL=$(CDPATH= cd -- "$KERNEL" && pwd)
[ -f "$KERNEL/kernel.config" ] && grep -Eq "^CONFIG_IPV6=(y|m)$" "$KERNEL/kernel.config" && grep -q "^CONFIG_NF_TABLES_IPV6=y$" "$KERNEL/kernel.config" || { echo "An IPv6-capable kernel is required; run scripts/build-linux-kernel.sh first." >&2; exit 1; }
VERSION=${DOCKER_ENGINE_VERSION:-29.9.3}
HASH=${DOCKER_ENGINE_SHA256:-}
if [ "$VERSION" = 29.9.3 ] && [ -z "$HASH" ]; then HASH=1b27fd739378ef938401e81ce5afb73b7ad7432d4f598814a9ff5f826bb464d2; fi
[ -n "$HASH" ] || { printf "DOCKER_ENGINE_SHA256 is required for this version\n" >&2; exit 2; }
case "$VERSION" in *[!0-9.]*|'') exit 2;; esac
CONTAINER=${MINIMAL_BUILD_CONTAINER:-$(docker create --platform linux/arm64 debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 sleep infinity)}
trap 'if [ -z "${MINIMAL_BUILD_CONTAINER:-}" ]; then docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; fi' EXIT
docker start "$CONTAINER" >/dev/null
docker exec "$CONTAINER" sh -ec 'rm -rf /source /rootfs /initroot /modules /output /kernel-system.raw /kernel-modules.tar.gz /kernel-version; mkdir -p /source'
docker cp "$ROOT/guest" "$CONTAINER:/source/guest"
docker cp "$ROOT/scripts/assemble-minimal-rootfs.py" "$CONTAINER:/assemble.py"
docker cp "$ROOT/scripts/select-kernel-modules.py" "$CONTAINER:/select-modules.py"
if [ -f "$KERNEL/modules.tar.gz" ]; then
    docker cp "$KERNEL/modules.tar.gz" "$CONTAINER:/kernel-modules.tar.gz"
else
    docker cp "$KERNEL/system.raw" "$CONTAINER:/kernel-system.raw"
fi
docker cp "$KERNEL/kernel-version" "$CONTAINER:/kernel-version"
docker exec -e DOCKER_ENGINE_VERSION="$VERSION" -e DOCKER_ENGINE_SHA256="$HASH" "$CONTAINER" sh -ec '
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev busybox-static python3 iproute2 iptables kmod e2fsprogs util-linux ca-certificates samba samba-common-bin iperf3 curl cpio zstd
mkdir -p /source /output /modules
python3 /assemble.py /rootfs /source
release=$(cat /kernel-version)
if [ -f /kernel-modules.tar.gz ]; then
    tar -xzf /kernel-modules.tar.gz -C /rootfs
else
    debugfs -R "rdump /lib/modules /modules" /kernel-system.raw
    test -d "/modules/modules/$release"
    cp -a /modules/modules /rootfs/lib/
fi
depmod -b /rootfs "$release"
curl -fL --retry 3 "https://download.docker.com/linux/static/stable/aarch64/docker-$DOCKER_ENGINE_VERSION.tgz" -o /docker.tgz
printf "%s  /docker.tgz\n" "$DOCKER_ENGINE_SHA256" | sha256sum -c -
mkdir -p "/rootfs/opt/docker/releases/$DOCKER_ENGINE_VERSION"
tar -xzf /docker.tgz -C "/rootfs/opt/docker/releases/$DOCKER_ENGINE_VERSION" --strip-components=1
ln -s "releases/$DOCKER_ENGINE_VERSION" /rootfs/opt/docker/current
for binary in /rootfs/opt/docker/current/*; do ln -s "/opt/docker/current/${binary##*/}" "/rootfs/usr/bin/${binary##*/}"; done
sha256sum /docker.tgz > "/rootfs/opt/docker/releases/$DOCKER_ENGINE_VERSION/archive.sha256"
mkdir -p /initroot/bin /initroot/dev /initroot/proc /initroot/sys /initroot/newroot /initroot/lib/modules
cp /bin/busybox /initroot/bin/
for applet in sh mount mkdir seq sleep switch_root; do ln -s busybox "/initroot/bin/$applet"; done
cp /source/guest/initramfs.sh /initroot/init
chmod 755 /initroot/init
python3 /select-modules.py /rootfs "$release" /initroot
mkdir -p /initroot/sbin /initroot/usr/lib/aarch64-linux-gnu
cp /usr/bin/kmod /initroot/sbin/kmod
ln -s kmod /initroot/sbin/modprobe
ldd /usr/bin/kmod | awk '\''/=> \// {print $3} /^\s*\// {print $1}'\'' | while read library; do mkdir -p "/initroot$(dirname "$library")"; cp -L "$library" "/initroot$library"; done
cp -L /lib/ld-linux-aarch64.so.1 /initroot/lib/
(cd /initroot && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -1 > /output/initramfs)
truncate -s 1024M /output/system.raw
mkfs.ext4 -F -L macosdocker-root -d /rootfs /output/system.raw
cp /rootfs/usr/share/macosdocker/build-packages.tsv /output/packages.txt
printf "Docker static %s\nmacOSDocker init; BusyBox utilities; no distribution package manager\n" "$DOCKER_ENGINE_VERSION" >> /output/packages.txt
du -sh /rootfs /output/initramfs
'
docker cp "$CONTAINER:/output/." "$OUTPUT/"
for name in vmlinuz kernel-version kernel.config kernel-source.sha256; do
    if [ "$KERNEL" != "$OUTPUT" ] && [ -f "$KERNEL/$name" ]; then cp "$KERNEL/$name" "$OUTPUT/$name"; fi
done
(cd "$OUTPUT" && shasum -a 256 vmlinuz initramfs system.raw > SHA256SUMS)
printf 'Minimal image created: %s\n' "$OUTPUT"
