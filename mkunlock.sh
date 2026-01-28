#!/bin/sh

# Builds on the setup outlined in this post https://sindro.me/posts/2023-08-13-freebsd-encrypted-root-on-zfs/
# to create a pre-boot environment with SSH to unlock the root filesystem and either chroot into it for maintenance,
# or to let the system finish booting.

set -e

#
# Configuration
#
WORKDIR="$(mktemp -d)"
OUTPUT_IMG="/boot/mfsroot"
DROPBEAR_PORT=4242
IFACE="vtnet0"
KEYFILE="/boot/geli/vtbd0p4.key"
BOOTPART="vtbd0p2"
ROOTPART="vtbd0p4"
# This exposes the root hash in the unencrypted volume, you can change if it's a concern to you
ROOT_HASH=$(grep "^root:" /etc/master.passwd | awk -F: '{print $2}')
ZFS_POOL="tank"
ZFS_ROOT="ROOT"

_cleanup() {
  echo ">>> Removing workdir $WORKDIR..."
  rm -rf "$WORKDIR"
}

trap _cleanup INT EXIT

echo ">>> Create unlock RAM disk started ..."

# 1. Create directory tree
mkdir -p "$WORKDIR"/bin
mkdir -p "$WORKDIR"/sbin
mkdir -p "$WORKDIR"/lib
mkdir -p "$WORKDIR"/lib/geom
mkdir -p "$WORKDIR"/libexec
mkdir -p "$WORKDIR"/etc
mkdir -p "$WORKDIR"/etc/pam.d
mkdir -p "$WORKDIR"/root/.ssh
mkdir -p "$WORKDIR"/usr/bin
mkdir -p "$WORKDIR"/usr/lib
mkdir -p "$WORKDIR"/usr/sbin
mkdir -p "$WORKDIR"/usr/share/misc
mkdir -p "$WORKDIR"/var/tmp
mkdir -p "$WORKDIR"/var/run
mkdir -p "$WORKDIR"/dev
mkdir -p "$WORKDIR"/tmp
mkdir -p "$WORKDIR"/ufsboot
ln -s /ufsboot/boot "$WORKDIR/boot"
ln -s /sbin "$WORKDIR/rescue"

# 2. Copy /rescue static binaries to /sbin
echo ">>> Copying /rescue contents to /sbin..."
tar -cf - -C /rescue . | tar -xf - -C "$WORKDIR/sbin/"

ln $WORKDIR/sbin/sh $WORKDIR/bin/sh

echo ">>> Copying some stuff from the host..."
cp -v /usr/share/misc/termcap* $WORKDIR/usr/share/misc
cp -v /etc/login.conf $WORKDIR/etc
cp -v /etc/resolv.conf $WORKDIR/etc

# 3. dropbear, geli and shlibs
DROPBEAR_BIN=$(which dropbear)
if [ -z "$DROPBEAR_BIN" ]; then
  echo "!!! ERROR: dropbear not found - install it via pkg install dropbear"
  exit 1
fi

GELI_BIN=$(which geli)
if [ -z "$GELI_BIN" ]; then
  echo "!!! ERROR: Can't find the geli binary?!"
  exit 1
fi

echo ">>> Copying dynamically-linked executables..."
cp -v "$DROPBEAR_BIN" "$WORKDIR/usr/sbin/dropbear"
cp -v "$GELI_BIN" "$WORKDIR/sbin/geli"
cp -v /lib/geom/geom_eli.so $WORKDIR/lib/geom
cp -v /usr/libexec/getty $WORKDIR/bin
cp -v /usr/bin/login $WORKDIR/usr/bin
cp -v /usr/lib/pam_unix.so $WORKDIR/usr/lib
cp -v /usr/lib/pam_permit.so $WORKDIR/usr/lib

DYN_BINS="$DROPBEAR_BIN $GELI_BIN /lib/geom/geom_eli.so /usr/libexec/getty /usr/bin/login /usr/lib/pam_unix.so /usr/lib/pam_permit.so"
for bin in $DYN_BINS; do
  ldd "$bin" | grep -Eo '/.+' | grep -v :$ | awk '{print $1}' | while read libpath; do
    libname=$(basename "$libpath")
    if [ ! -f "$WORKDIR/lib/$libname" ]; then
      cp -v "$libpath" "$WORKDIR/lib/$libname"
    fi
  done
done

cp -v /libexec/ld-elf.so.1 "$WORKDIR/libexec/"

# 4. SSH keys
echo ">>> Converting host SSH keys to dropbear format..."

DROPBEAR_KEYS=""
for hostkey in /etc/ssh/ssh_host_*_key; do
  case $hostkey in
    *_dsa_*) continue ;;
    *)
      keyfile="/etc/$(basename $hostkey)"
      dropbearconvert openssh dropbear $hostkey "$WORKDIR$keyfile"
      DROPBEAR_KEYS="$DROPBEAR_KEYS -r $keyfile"
    ;;
  esac
done

if [ -f /root/.ssh/authorized_keys ]; then
  cp -v /root/.ssh/authorized_keys "$WORKDIR/root/.ssh/"
  chmod 600 "$WORKDIR/root/.ssh/authorized_keys"
else
  echo "!!! ERROR missing /root/.ssh/authorized_keys!"
  exit 1
fi

echo "root:*:0:0:Charlie Root:/root:/bin/sh" > "$WORKDIR/etc/passwd"
echo "root:$ROOT_HASH:0:0::0:0:Superuser:/root:/bin/sh" > "$WORKDIR/etc/master.passwd"
echo "wheel:*:0:root" > "$WORKDIR/etc/group"
pwd_mkdb -d "$WORKDIR/etc" "$WORKDIR/etc/master.passwd"
echo "/bin/sh" > "$WORKDIR/etc/shells"

# Copy GELI keyfile
if [ -n "$KEYFILE" -a -f "$KEYFILE" ]; then
  cp -v "$KEYFILE" "$WORKDIR/etc/rootpart.key"
fi

# Network config
echo ">>> Generate network configuration..."
IPV4=$(sysrc -n ifconfig_${IFACE})
IPV6=$(sysrc -n ifconfig_${IFACE}_ipv6)
GW4=$(sysrc -n defaultrouter)
GW6=$(sysrc -n ipv6_defaultrouter)
HOSTNAME=$(sysrc -n hostname)

# Generate RC script
cat > "$WORKDIR/etc/rc" <<EOF
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/lib

echo ">>> RC: Welcome to the unlock pre-boot environment."

mount -t devfs devfs /dev
mount -uw /
mount /ufsboot

echo ">>> Configuring network ($IFACE)..."
hostname $HOSTNAME
ifconfig $IFACE inet $IPV4 up
route add default $GW4

ifconfig $IFACE $IPV6
route -6 add default $GW6

echo ">>> Starting dropbear..."
/usr/sbin/dropbear -E -s -p $DROPBEAR_PORT $DROPBEAR_KEYS

echo ">>> Ready."
EOF
chmod +x "$WORKDIR/etc/rc"

cat > "$WORKDIR/etc/gettytab" <<EOF
default:\
  :cb:ce:ck:lc:fd#1000:im=\r\nSystem Locked - Identify Yourself\r\n:sp#115200:

Rescue:\
  :tc=default:np:ht:
EOF

cat > "$WORKDIR/etc/motd" <<EOF
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
 ____  _____ ____   ____ _   _ _____ 
|  _ \\| ____/ ___| / ___| | | | ____|
| |_) |  _| \\___ \\| |   | | | |  _|  
|  _ <| |___ ___) | |___| |_| | |___ 
|_| \\_\\_____|____/ \\____|\\___/|_____|

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

- unlock.sh : unlocks root
- boot.sh : boots multi-user (requires unlock.sh)
- enter.sh : enters system chroot (requires unlock.sh)

Have fun!
EOF

cat > "$WORKDIR/etc/ttys" <<EOF
console "/bin/getty Rescue" xterm on insecure
EOF

cat > "$WORKDIR/etc/pam.d/login" <<EOF
auth        required    pam_unix.so
account     required    pam_unix.so
session     required    pam_permit.so
password    required    pam_permit.so
EOF

cat > "$WORKDIR/etc/fstab" <<EOF
/dev/md0 / ufs rw 0 0
/dev/$BOOTPART /ufsboot ufs ro 0 0
EOF

# Unlock script
cat > "$WORKDIR/bin/unlock.sh" <<EOF
#!/bin/sh
GELI_DEV="/dev/$ROOTPART"
KEYFILE="/etc/rootpart.key"

echo ">>> Attempting to unlock \$GELI_DEV..."
if [ -f \$KEYFILE ]; then
  geli attach -k "\$KEYFILE" "\$GELI_DEV"
else
  geli attach "\$GELI_DEV"
fi

if [ \$? -eq 0 ]; then
  echo ">>> \$GELI_DEV unlocked."
else
  echo ">>> ERROR: Wrong password. \$GELI_DEV still locked."
fi
EOF
chmod +x "$WORKDIR/bin/unlock.sh"

# Boot script
cat > "$WORKDIR/bin/boot.sh" <<EOF
#!/bin/sh
if [ ! -c /dev/$ROOTPART.eli ]; then
  echo "!!! ERROR: Disk not unlocked yet! Run unlock.sh first"
  exit 1
fi

kenv vfs.root.mountfrom="zfs:$ZFS_POOL/$ZFS_ROOT"

umount /ufsboot
mount -ur /

/sbin/reboot -r
EOF
chmod +x "$WORKDIR/bin/boot.sh"

cat > "$WORKDIR/bin/enter.sh" <<EOF
#!/bin/sh

MOUNTPOINT="/tmp/zroot"

if [ ! -c /dev/$ROOTPART.eli ]; then
  echo "!!! ERROR: Disk not unlocked yet! Run unlock.sh first"
  exit 1
fi

echo ">>> Setting up chroot..."
mkdir -p "\$MOUNTPOINT"

echo ">>> Import ZFS pool '$ZFS_POOL' to \$MOUNTPOINT..."
zpool import -R "\$MOUNTPOINT" "$ZFS_POOL"

if [ \$? -ne 0 ]; then
  echo "!!! ERROR: Import failed."
  exit 1
fi

echo ">>> Mounting devfs in chroot..."
mount -t devfs devfs "\$MOUNTPOINT/dev"

echo ">>> -----------------------------------------------------------"
echo ">>> You are in the chrooted environment. Type 'exit' to go back"
echo ">>> -----------------------------------------------------------"

chroot "\$MOUNTPOINT" /rescue/sh

echo ">>> Unmounting devfs..."
umount "\$MOUNTPOINT/dev"

echo ">>> Exporting the pool" 
zpool export "$ZFS_POOL"

echo ">>> Done. Use boot.sh to boot!"
EOF
chmod +x "$WORKDIR/bin/enter.sh"

# Packaging
SIZE=$(du -ms "$WORKDIR" | awk '{print $1 + 10}')
echo ">>> Calculated size: ${SIZE}MB"

makefs -b "${SIZE}m" "$OUTPUT_IMG" "$WORKDIR"
gzip -f "$OUTPUT_IMG"

echo ">>> Done. mfsroot created in $OUTPUT_IMG.gz"
