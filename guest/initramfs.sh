#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
for module in virtio_pci virtio_blk virtio_console ext4; do
    /sbin/modprobe "$module" || exec sh
 done
mkdir -p /newroot
for attempt in $(seq 1 100); do
    [ -b /dev/vda ] && break
    sleep 0.1
done
mount -t ext4 -o rw /dev/vda /newroot || exec sh
mount --move /dev /newroot/dev
mount --move /sys /newroot/sys
mount --move /proc /newroot/proc
exec switch_root /newroot /sbin/init
