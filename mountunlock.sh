#!/bin/sh

set -x

image="$(mktemp)"
mountpoint="$(mktemp -d)"

gunzip -c /boot/mfsroot.gz > "$image"
mkdir -p "$mountpoint"
loopdev="$(mdconfig $image)"
mount "/dev/$loopdev" "$mountpoint"
mount -t devfs /dev "$mountpoint/dev"
cd $mountpoint
echo ">>> Running chrooted shell in $mountpoint, I'll clean up when it exits."

chroot $mountpoint /bin/sh
#$SHELL

cd -
umount "$mountpoint/dev"
umount "$mountpoint"
mdconfig -d -u "$loopdev"

rm -f "$image"
rm -xrf "$mountpoint"
