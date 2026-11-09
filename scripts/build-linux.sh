#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-"$ROOT/build/linux"}
KERNEL=${KERNEL_IMAGE_DIR:-"$ROOT/build/linux"}
if [ -f "$KERNEL/vmlinuz" ] && [ -f "$KERNEL/kernel-version" ] && [ -f "$KERNEL/kernel.config" ] && grep -Eq "^CONFIG_IPV6=(y|m)$" "$KERNEL/kernel.config" && grep -q "^CONFIG_NF_TABLES_IPV6=y$" "$KERNEL/kernel.config" && { [ -f "$KERNEL/system.raw" ] || [ -f "$KERNEL/modules.tar.gz" ]; }; then
    exec "$ROOT/scripts/build-minimal-linux.sh" "$OUTPUT"
fi
exec "$ROOT/scripts/build-linux-kernel.sh" "$OUTPUT"
