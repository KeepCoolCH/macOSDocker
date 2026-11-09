#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /run /tmp /dev/pts /dev/shm /sys/fs/cgroup
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /run
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /tmp
mount -t devpts -o mode=620,gid=5 devpts /dev/pts
mount -t tmpfs -o mode=1777,nosuid,nodev,size=64m tmpfs /dev/shm
mount -t cgroup2 cgroup2 /sys/fs/cgroup
mount --make-rshared /
mkdir -p /etc/modprobe.d
printf 'install macvlan /bin/false\n' > /etc/modprobe.d/macosdocker-macvlan.conf
hostname macosdocker
/sbin/modprobe virtio_net
/sbin/modprobe virtiofs
/sbin/modprobe vmw_vsock_virtio_transport
sysctl -w net.ipv4.ip_forward=1
mkdir -p /macos /var/lib/macosdocker /var/lib/docker /var/lib/containerd /run/macosdocker /run/containerd
kind=$(blkid -o value -s TYPE /dev/vdb || true)
if [ -z "$kind" ]; then
    if blkid -p /dev/vdb >/dev/null 2>&1; then
        printf 'Unrecognized data disk signature\n' >&2
        exit 1
    fi
    mkfs.ext4 -L macosdocker-data /dev/vdb
elif [ "$kind" != ext4 ]; then
    printf 'Data disk must be ext4\n' >&2
    exit 1
fi
mount /dev/vdb /var/lib/docker
mkdir -p /var/lib/docker/.containerd
mount --bind /var/lib/docker/.containerd /var/lib/containerd
macosdocker-service networking start >> /var/log/network.log 2>&1 &
touch /run/macosdocker/boot.ready
printf 'macOSDocker minimal userspace ready\n'
