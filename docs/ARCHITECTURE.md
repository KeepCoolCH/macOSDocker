# Architecture

The SwiftUI app manages a Linux VM through Apple's Virtualization.framework. The VM uses Virtio devices for storage, networking, console, entropy, VirtioFS and vsock. `RuntimeManager` controls startup, shutdown and restart. The menu bar and dashboard share one runtime.

## Linux and Docker

The custom ARM64 kernel is built from `guest/kernel.config` and supports IPv4 and optional IPv6. IPv6 is disabled by default and the opt-in creation policy applies only to new containers and networks. The base image contains a custom init process, BusyBox, the Python guest service, Docker Engine, containerd, runc and Samba. No full distribution, systemd or package manager is installed. Debian is used only as the build environment.

System and Docker data disks are separate. Base image updates preserve the data disk and create a safety backup first. Docker updates use verified static binary packages and revert to the previous binaries if startup fails. Container resumption reconciles vanished IDs and containers already running after external recreation. Start failures for existing stopped containers remain errors.

## Communication

Docker API and guest control traffic use vsock through local Unix sockets. The bundled Docker CLI, Compose and Buildx use the same Docker endpoint. A terminal context is registered, and runtime tools allow switching the global terminal default.

The guest service reports readiness, capabilities and IPv4 addresses. Startup prepares networking and shares before Docker starts containers with restart policies. Docker events and periodic reconciliation update inventory.

## Networking

NAT uses `VZNATNetworkDeviceAttachment`. `TCPPortForwarder` also exposes published IPv4 TCP ports on the Mac. This forwarding does not preserve the original client IP.

Bridge mode uses `VZBridgedNetworkDeviceAttachment` with the selected adapter and requires `com.apple.vm.networking` in the signing profile. The VM obtains its own LAN IP. Docker macvlan is available only in bridge mode. Docker bridge networks are independent of the VM's network attachment. Internal Docker bridges and both ends of their container veth links use MTU 65535. The VM uplink and physical adapters keep their existing MTU. Docker events and periodic reconciliation apply this to existing bridge networks and newly attached containers. Bridges with physical or other non-veth members, macvlan, ipvlan and host networking are excluded.

## Files and backups

One VirtioFS device exposes configured Mac directories through `VZMultipleDirectoryShare`, with a stable key and independent read-only setting for each directory. The guest bind-mounts each directory at its resolved path. There is no fixed share-count limit. Automatic sharing of `/Users` and `/Volumes` can be enabled independently. Available paths are mounted in the VM root; conflicts with Linux system paths use the full Mac path below `/macos`. The Docker socket remains a VM system path.

Docker volumes live on the data disk and can be opened in Finder through Samba. Full backups include the system and Docker data. On APFS, cloning reduces the time the VM must remain stopped. Other filesystems use regular copying. Volume archives and scheduled backups complement full backups.

## Project contents

The project contains production sources, resources, build and release tools, and required license texts. Tests, historical diagnostic reports and test integration are archived outside the project directory and are not compiled into the app.

## Shutdown

Normal stop, restart and app termination first disconnect the SMB mounts managed by the app. If a mount cannot be cleanly disconnected, the VM remains running. The guest then sends SIGTERM to Docker Engine so Docker initiates its normal parallel container shutdown without marking containers as manually stopped. The guest waits up to three seconds for Docker to exit, then calls sync before acknowledging preparation. The app subsequently powers off the VM through Virtualization.framework. Preparation failures prevent automatic power-off; Force Stop remains available. The three-second window is a best-effort opportunity for applications to exit, not a guarantee: remaining applications may retain unwritten data or continue writing during sync. Sync only flushes data already submitted to the kernel and can take longer than the grace window. Force Stop bypasses this preparation. The full guest shutdown service remains available for explicit guest-side shutdown.

Guests that return HTTP 404 for `/prepare-poweroff` use the legacy `/shutdown` endpoint instead. The app waits up to 40 seconds for shutdown before allowing an image replacement. Other preparation errors still prevent automatic power-off. This compatibility path allows an older installed image to be updated without a forced stop.
