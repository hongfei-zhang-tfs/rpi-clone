#!/bin/bash
#
# factory-flash.sh
#
# Purpose: 
#  - Automate cloning of the running USB OS to eMMC for Raspberry Pi
#  - Expand filesystem
#  - Update PARTUUID references in cmdline.txt & fstab
#  - Single-run logic with a FACTORY_DONE marker
#

set -e

LOGFILE="/var/log/factory-flash.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== Factory Flash Script Started ==="

# 1. Check if we are running on USB root (/dev/sda2 or /dev/sdaX).
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" != /dev/sd* ]]; then
  echo "ERROR: Root device ($ROOT_DEV) is not a USB disk. Exiting."
  exit 1
fi
echo "Root device is $ROOT_DEV, continuing."

EMMC_DEV="/dev/mmcblk0"
if [ ! -b "$EMMC_DEV" ]; then
  echo "ERROR: eMMC device $EMMC_DEV not found. Exiting."
  exit 1
fi

echo "Checking if eMMC is already flashed with marker..."

MOUNTDIR="/mnt/emmc"
sudo mkdir -p "$MOUNTDIR"

# Try mounting the eMMC root partition (p2). 
# - If it's not partitioned or can't be mounted, ignore the error (we'll do the clone anyway).
sudo mount "${EMMC_DEV}p2" "$MOUNTDIR" || true

MARKER_FILE="$MOUNTDIR/boot/FACTORY_DONE"
if [ -f "$MARKER_FILE" ]; then
  echo "FACTORY_DONE marker found at $MARKER_FILE"
  echo "Skipping clone; eMMC already flashed."
  sudo umount "$MOUNTDIR" || true
  exit 0
fi

# If the partition was mounted, unmount before we do rpi-clone
sudo umount "$MOUNTDIR" || true

echo "No FACTORY_DONE marker detected; proceeding with clone..."

# 2. Clone the OS from USB to eMMC with rpi-clone
echo "Cloning via rpi-clone..."
# -f   = force overwrite
# -v   = verbose
# -U   = skip user prompt
# -x   = expand the root partition to fill the card
rpi-clone -f -v -U -x mmcblk0

# 3. Mount the newly cloned eMMC root + boot so we can modify cmdline.txt & fstab
echo "Mounting eMMC partitions..."
sudo mkdir -p "$MOUNTDIR"
sudo mount "${EMMC_DEV}p2" "$MOUNTDIR"
sudo mkdir -p "$MOUNTDIR/boot"
sudo mount "${EMMC_DEV}p1" "$MOUNTDIR/boot"

# 4. Read the new PARTUUIDs from the eMMC
NEW_BOOT_PARTUUID=$(blkid -s PARTUUID -o value "${EMMC_DEV}p1")
NEW_ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${EMMC_DEV}p2")

echo "=== Detected eMMC PARTUUIDs ==="
echo "BOOT PARTUUID = $NEW_BOOT_PARTUUID"
echo "ROOT PARTUUID = $NEW_ROOT_PARTUUID"

# 5. Update /boot/cmdline.txt
CMDLINE="$MOUNTDIR/boot/cmdline.txt"

if grep -q "root=PARTUUID=" "$CMDLINE"; then
  echo "Updating existing PARTUUID in cmdline.txt to root=PARTUUID=$NEW_ROOT_PARTUUID"
  sudo sed -i "s|\(root=PARTUUID=\)\S*|\1$NEW_ROOT_PARTUUID|g" "$CMDLINE"
elif grep -q "root=/dev/sd" "$CMDLINE"; then
  echo "Replacing /dev/sdaX with root=PARTUUID=$NEW_ROOT_PARTUUID in cmdline.txt"
  sudo sed -i "s|root=/dev/sda2|root=PARTUUID=$NEW_ROOT_PARTUUID|g" "$CMDLINE"
elif grep -q "root=/dev/mmcblk0p2" "$CMDLINE"; then
  echo "Replacing /dev/mmcblk0p2 with root=PARTUUID=$NEW_ROOT_PARTUUID in cmdline.txt"
  sudo sed -i "s|root=/dev/mmcblk0p2|root=PARTUUID=$NEW_ROOT_PARTUUID|g" "$CMDLINE"
else
  echo "No recognizable root= line found in cmdline.txt; appending root=PARTUUID=$NEW_ROOT_PARTUUID"
  sudo sed -i "s|\(root=\)\S*|\1PARTUUID=$NEW_ROOT_PARTUUID|g" "$CMDLINE"
fi

# 6. Update /etc/fstab on the eMMC root
FSTAB="$MOUNTDIR/etc/fstab"

# Replace existing PARTUUIDs if present
if grep -q "PARTUUID=" "$FSTAB"; then
  echo "Replacing existing PARTUUID entries in /etc/fstab..."
  sudo sed -i "s|PARTUUID=[^ ]*-01|PARTUUID=$NEW_BOOT_PARTUUID|g" "$FSTAB"
  sudo sed -i "s|PARTUUID=[^ ]*-02|PARTUUID=$NEW_ROOT_PARTUUID|g" "$FSTAB"
fi

# Replace any /dev references if found
if grep -q "/dev/sda1" "$FSTAB"; then
  echo "Replacing /dev/sda1 with PARTUUID=$NEW_BOOT_PARTUUID in fstab..."
  sudo sed -i "s|/dev/sda1|PARTUUID=$NEW_BOOT_PARTUUID|g" "$FSTAB"
fi
if grep -q "/dev/sda2" "$FSTAB"; then
  echo "Replacing /dev/sda2 with PARTUUID=$NEW_ROOT_PARTUUID in fstab..."
  sudo sed -i "s|/dev/sda2|PARTUUID=$NEW_ROOT_PARTUUID|g" "$FSTAB"
fi
if grep -q "/dev/mmcblk0p1" "$FSTAB"; then
  echo "Replacing /dev/mmcblk0p1 with PARTUUID=$NEW_BOOT_PARTUUID in fstab..."
  sudo sed -i "s|/dev/mmcblk0p1|PARTUUID=$NEW_BOOT_PARTUUID|g" "$FSTAB"
fi
if grep -q "/dev/mmcblk0p2" "$FSTAB"; then
  echo "Replacing /dev/mmcblk0p2 with PARTUUID=$NEW_ROOT_PARTUUID in fstab..."
  sudo sed -i "s|/dev/mmcblk0p2|PARTUUID=$NEW_ROOT_PARTUUID|g" "$FSTAB"
fi

# 7. Create FACTORY_DONE marker
MARKER_FILE="$MOUNTDIR/boot/FACTORY_DONE"
echo "Creating FACTORY_DONE marker at $MARKER_FILE"
sudo touch "$MARKER_FILE"

sync

# 8. Unmount eMMC
echo "Unmounting eMMC..."
sudo umount "$MOUNTDIR/boot" || true
sudo umount "$MOUNTDIR" || true

echo "=== eMMC flash complete. FACTORY_DONE marker created. ==="

# 9. Optionally shut down to signal completion
echo "Shutting down system in 5 seconds..."
sleep 5
sudo shutdown -h now
