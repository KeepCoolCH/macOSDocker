# Custom VM kernel

`scripts/build-linux-kernel.sh` builds Linux 7.3.1 for ARM64 and then assembles the minimal base image. `KERNEL_VERSION` and `KERNEL_JOBS` select the version and compiler parallelism. `DOCKER_HOST` selects the Docker endpoint.

Kernel sources are downloaded from cdn.kernel.org and checked against its published SHA-256 checksums. Configuration lives in `guest/kernel.config`; IPv6 support is built in, but interface IPv6 is disabled at boot with `ipv6.disable_ipv6=1`. The guest enables it only when requested; the Docker creation policy defaults to IPv4. The kernel, modules and initramfs are built together. The release suffix is `-macosdocker`.

Direct kernel builds default to `build/linux-kernel-7.3.1`. Validate the result in an isolated VM before promoting it to `build/linux` for bundling. Obsolete image backups and separate test builds have been removed. The active base image exists only in `build/linux`; app builds contain their bundled copy.

Kernel updates are delivered through new base images. Updating Docker Engine does not update the kernel. Existing installations install the new base image through Runtime; the separate Docker data disk is preserved.

Validation covered boot, DHCP and static IPv4, Docker, Compose, Buildx, VirtioFS, SMB, base image replacement and data persistence across restarts.
