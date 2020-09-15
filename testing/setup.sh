#!/bin/bash
IMAGE="ztest.img"
ENCRYPTED=0
while getopts "eh" opt; do
  case "${opt}" in
    e)
      ENCRYPTED=1
      IMAGE="ztest-encrypted.img"
      echo "Creating an encrypted test pool"
      echo "Pool passphrase: zfsbootmenu"
      ;;
    *)
      ;;
  esac
done

MNT="$( mktemp -d )"
LOOP="$( losetup -f )"

qemu-img create "${IMAGE}" 1G

losetup "${LOOP}" "${IMAGE}" 
kpartx -u "${LOOP}"

echo 'label: gpt' | sfdisk "${LOOP}"

echo "zfsbootmenu" > "$( pwd )/ztest.key"

if ((ENCRYPTED)) ; then
  ENC_ARGS="-O encryption=aes-256-gcm \
    -O keylocation=file:///$( pwd )/ztest.key \
    -O keyformat=passphrase"
else
  ENC_ARGS=""
fi

zpool create -f \
 -O compression=lz4 \
 -O acltype=posixacl \
 -O xattr=sa \
 -O relatime=on \
 -o autotrim=on \
 -o cachefile=none \
 "${ENC_ARGS}" \
 -m none ztest "${LOOP}"

zfs snapshot -r ztest@barepool

zfs create -o mountpoint=none ztest/ROOT
zfs create -o mountpoint=/ -o canmount=noauto ztest/ROOT/void

zfs snapshot -r ztest@barebe

zfs set org.zfsbootmenu:commandline="spl_hostid=$( hostid ) ro quiet" ztest/ROOT
zpool set bootfs=ztest/ROOT/void ztest

zpool export ztest
zpool import -R "${MNT}" ztest
zfs mount ztest/ROOT/void

case "$(uname -m)" in
  ppc64le)
    URL="https://mirrors.servercentral.com/void-ppc/current"
    ;;
  x86_64)
    URL="https://mirrors.servercentral.com/voidlinux/current"
    ;;
esac

# https://github.com/project-trident/trident-installer/blob/master/src-sh/void-install-zfs.sh#L541
mkdir -p "${MNT}/var/db/xbps/keys"
cp /var/db/xbps/keys/*.plist "${MNT}/var/db/xbps/keys/."

mkdir -p "${MNT}/etc/xbps.d"
cp /etc/xbps.d/*.conf "${MNT}/etc/xbps.d/."

# /etc/runit/core-services/03-console-setup.sh depends on loadkeys from kbd
# /etc/runit/core-services/05-misc.sh depends on ip from iproute2
xbps-install -y -S -M -r "${MNT}" --repository="${URL}" \
  base-minimal dracut ncurses-base kbd iproute2

cp /etc/hostid "${MNT}/etc/"
cp /etc/resolv.conf "${MNT}/etc/"
cp /etc/rc.conf "${MNT}/etc/"

mount -t proc proc "${MNT}/proc"
mount -t sysfs sys "${MNT}/sys"
mount -B /dev "${MNT}/dev"
mount -t devpts pts "${MNT}/dev/pts"

zfs snapshot -r ztest@pre-chroot

cp chroot.sh "${MNT}/root"
chroot "${MNT}" /root/chroot.sh

umount -R "${MNT}" && rmdir "${MNT}"

zpool export ztest
losetup -d "${LOOP}"

chown "$( stat -c %U . ):$( stat -c %G . )" "${IMAGE}" 

# Setup a local config file
if [ ! -f local.yaml ]; then
  cp ../etc/zfsbootmenu/config.yaml local.yaml
  yq-go w -i local.yaml Components.ImageDir "$( pwd )"
  yq-go w -i local.yaml Components.Versions false
  yq-go w -i local.yaml Global.ManageImages true
  yq-go d -i local.yaml Global.BootMountPoint
fi
