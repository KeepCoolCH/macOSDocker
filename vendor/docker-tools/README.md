# Bundled Docker tools

Official upstream binaries are pinned and verified by `scripts/bundle-docker-tools.sh`:

- Docker CLI 29.9.3: https://download.docker.com/mac/static/stable/aarch64/docker-29.9.3.tgz
  Source: https://github.com/docker/cli/tree/v29.9.3
- Compose 5.5.1: https://github.com/docker/compose/releases/tag/v5.5.1
- Buildx 0.37.0: https://github.com/docker/buildx/releases/tag/v0.37.0

All three projects use Apache-2.0. License texts are included alongside the binaries. Compose and Buildx SHA-256 values come from upstream release asset metadata. The Docker archive checksum pins the archive downloaded from Docker's HTTPS server. Binaries target Apple Silicon, matching the ARM64 guest architecture.

The bundled Linux image uses a custom kernel and a minimal userspace assembled from selected Debian packages. No complete distribution or package manager is installed in the guest. Docker Engine, containerd and runc come from Docker's official static Linux archive. Installed components and license information are recorded in `LinuxImage/packages.txt` and the Linux image's license directories.

Kernel sources: https://www.kernel.org/
Debian package sources and licensing: https://packages.debian.org/bookworm/
Docker static binaries: https://download.docker.com/linux/static/stable/aarch64/

Guest customization sources and reproducible build scripts are in `guest/` and `scripts/` in this repository.
