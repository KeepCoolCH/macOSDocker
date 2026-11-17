# Custom VM kernel

`scripts/build-linux-kernel.sh` builds Linux 7.3.1 for ARM64 and then assembles the minimal base image. `KERNEL_VERSION` and `KERNEL_JOBS` select the version and compiler parallelism. `DOCKER_HOST` selects the Docker endpoint.

Kernel sources are downloaded from cdn.kernel.org and checked against its published SHA-256 checksums. Configuration lives in `guest/kernel.config`; IPv6 support is built in, but interface IPv6 is disabled at boot with `ipv6.disable_ipv6=1`. The guest enables it only when requested; the Docker creation policy defaults to IPv4. The kernel, modules and initramfs are built together. The configuration targets the devices exposed by Virtualization.framework rather than unrelated physical boards and peripherals. Container namespaces, cgroups, security filters, BPF, optional IPv6, macvlan/ipvlan, supported filesystems, KVM and CPU idle support are retained. The release suffix is `-macosdocker`.

Direct kernel builds default to `build/linux-kernel-7.3.1`. Validate the result in an isolated VM before promoting it to `build/linux` for bundling. Obsolete image backups and separate test builds have been removed. The active base image exists only in `build/linux`; app builds contain their bundled copy.

Kernel updates are delivered through new base images. Updating Docker Engine does not update the kernel. Existing installations install the new base image through Runtime; the separate Docker data disk is preserved.

Validation covered boot, DHCP and static IPv4, Docker, Compose, Buildx, VirtioFS, SMB, base image replacement and data persistence across restarts.

## Boot optimizations

Virtio PCI, block storage, console, networking, ballooning, entropy, vsock, VirtioFS and ext4 are built into the default kernel. The initramfs therefore needs only BusyBox and the root-switch script. Builds using a custom configuration with modular boot drivers still include the required modules, kmod and its libraries automatically. Runtime kernel modules are installed with debug symbols stripped; their functionality and loadable module support are retained.

Patches in `guest/kernel-patches/` are applied before compilation. The Virtio PCI reset patch uses short timer sleeps while preserving the existing reset completion checks. A patch that does not apply cleanly stops the build. See the [patch documentation](../guest/kernel-patches/README.md) for provenance and comparison builds. `KERNEL_PATCH_DIR` can point to an empty directory to disable patches for a comparison.

The optimization does not shorten container stop timeouts or remove filesystem synchronization. App and Docker readiness remain separate from the kernel's boot time. Compare complete startup and shutdown with identical CPU, RAM, network, storage and container configurations.

The isolated validation includes Docker resource limits, named-volume persistence, read/write and read-only VirtioFS binds, bridge DNS, published TCP ports, two macvlan and two ipvlan containers on an isolated dummy parent, optional IPv6, SMB2 negotiation, Compose and BuildKit. The full app is also checked with more than 16 shares, live additions, removal while stopped, restarts and native Ethernet bridge DHCP. Test fixtures and the previous image are stored outside the repository.
