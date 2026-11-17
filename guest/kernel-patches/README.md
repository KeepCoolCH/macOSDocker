# Kernel patches

`0001-virtio-pci-fast-reset.patch` retains the existing Virtio PCI reset checks but changes their polling delay from `msleep(1)` to `usleep_range(10, 50)`. This avoids rounding each short reset wait to a full scheduler tick. It does not bypass a reset or change networking, storage or container shutdown semantics.

The change is based on the Virtio reset patch in [Kiri, commit 218253184bce9ca6926a82c132577b6d0bd482fa](https://github.com/libracoder/kiri/tree/218253184bce9ca6926a82c132577b6d0bd482fa/guest/kernel/patches). It modifies Linux kernel code covered by the kernel's GPL-2.0 licensing.

`scripts/build-linux-kernel.sh` applies the patches before compiling and fails if a patch does not apply cleanly. To build a comparison without patches, set `KERNEL_PATCH_DIR` to an empty directory. Applied patch files are included beside the generated kernel in `kernel-patches/`.

Validate new kernel versions with repeated VM starts and clean shutdowns, Docker workloads, VirtioFS and network tests before replacing the bundled image.
