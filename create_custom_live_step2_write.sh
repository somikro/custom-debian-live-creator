#!/bin/bash
# create_custom_live_step2_write.sh
# Recompress custom squashfs and write complete Debian Live USB
#
# Usage: sudo ./create_custom_live_step2_write.sh <variant-name> /dev/sdX [temp-dir]
#        (where variant-name is the custom variant and sdX is your target USB device)
#        Optional temp-dir: Directory for squashfs processing (e.g., RAM disk)
#        If not specified, variant directory is used
#
# WARNING: This will DESTROY ALL DATA on the target USB device!

script_name=$(basename "$0")
version="1.1"
startTS=$(date +%s.%N)
# Version history:
# 1.1 - Added versioned backup of custom squashfs for iterative workflow
# 1.0 - Initial release

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Get the actual user (not root) for file ownership
if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_UID="$SUDO_UID"
    ACTUAL_GID="$SUDO_GID"
else
    ACTUAL_USER=$(whoami)
    ACTUAL_UID=$(id -u)
    ACTUAL_GID=$(id -g)
fi

if [ $# -eq 0 ]; then
    echo "ERROR: Missing required arguments - both variant name and device must be specified"
    echo ""
    echo "Usage: $0 <variant-name> <device> [temp-dir]"
    echo "Example: $0 ca-system /dev/sdb"
    echo "Example: $0 ca-system /dev/sdb /mnt/ramdisk"
    echo ""
    echo "Available variants:"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for variant_dir in "$SCRIPT_DIR"/*/; do
        if [ -d "$variant_dir" ] && [ -f "$variant_dir/.custom_live_state" ]; then
            echo "  - $(basename "$variant_dir")"
        fi
    done
    echo ""
    echo "WARNING: This will ERASE ALL DATA on the specified device!"
    exit 1
elif [ $# -eq 1 ]; then
    echo "ERROR: Missing device parameter - you must specify both the variant name AND the target device"
    echo ""
    echo "Usage: $0 <variant-name> <device> [temp-dir]"
    echo "Example: $0 $1 /dev/sdb"
    echo ""
    echo "WARNING: This will ERASE ALL DATA on the specified device!"
    exit 1
elif [ $# -gt 3 ]; then
    echo "ERROR: Too many arguments provided"
    echo ""
    echo "Usage: $0 <variant-name> <device> [temp-dir]"
    echo "Example: $0 ca-system /dev/sdb"
    echo "Example: $0 ca-system /dev/sdb /mnt/ramdisk"
    echo ""
    echo "Available variants:"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for variant_dir in "$SCRIPT_DIR"/*/; do
        if [ -d "$variant_dir" ] && [ -f "$variant_dir/.custom_live_state" ]; then
            echo "  - $(basename "$variant_dir")"
        fi
    done
    echo ""
    echo "WARNING: This will ERASE ALL DATA on the specified device!"
    exit 1
fi

VARIANT_NAME=$1
DEVICE=$2
TEMP_DIR_PARAM="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIANT_DIR="$SCRIPT_DIR/$VARIANT_NAME"
STATE_FILE="$VARIANT_DIR/.custom_live_state"

# Determine working directory for squashfs
if [ -n "$TEMP_DIR_PARAM" ]; then
    if [ ! -d "$TEMP_DIR_PARAM" ]; then
        echo "ERROR: Specified temp directory does not exist: $TEMP_DIR_PARAM"
        exit 1
    fi
    SQUASHFS_WORK_DIR="$TEMP_DIR_PARAM"
    echo "Using temp directory for squashfs processing: $SQUASHFS_WORK_DIR"
else
    SQUASHFS_WORK_DIR="$VARIANT_DIR"
    echo "Using variant directory for squashfs processing: $SQUASHFS_WORK_DIR"
fi

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: Variant '$VARIANT_NAME' not found or state file missing"
    echo "Run create_custom_live_step1_extract.sh first"
    exit 1
fi

# Load state
source "$STATE_FILE"

# The statefile has been prepared in step 1. It contains:
# EXTRACT_DIR - directory where the custom live system is extracted
# ISO_FILE    - path to the original Debian Live ISO
# SQUASHFS_READY - (optional) indicates squashfs has been successfully created    

if [ ! -f "$ISO_FILE" ]; then
    echo "ERROR: Original ISO file not found: $ISO_FILE"
    exit 1
fi

if [ ! -d "$EXTRACT_DIR" ]; then
    echo "ERROR: Extract directory not found: $EXTRACT_DIR"
    exit 1
fi

# Validate device
if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a valid block device"
    exit 1
fi

# Safety check - prevent accidentally wiping system disk
if [[ "$DEVICE" == "/dev/sda" ]] || [[ "$DEVICE" == "/dev/nvme0n1" ]]; then
    read -p "WARNING: $DEVICE might be your system disk! Continue? (type YES to proceed): " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Check for required tools
for cmd in mksquashfs parted mkfs.vfat mkfs.ext4 grub-install rsync; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: Required command '$cmd' not found"
        if [ "$cmd" = "mksquashfs" ]; then
            echo "Install with: sudo apt install squashfs-tools"
        elif [ "$cmd" = "mkfs.vfat" ]; then
            echo "Install with: sudo apt install dosfstools"
        elif [ "$cmd" = "grub-install" ]; then
            echo "Install with: sudo apt install grub-efi-amd64-bin grub2-common"
        elif [ "$cmd" = "rsync" ]; then
            echo "Install with: sudo apt install rsync"
        fi
        exit 1
    fi
done

# Get USB size in GB
USB_SIZE=$(lsblk -b -d -n -o SIZE "$DEVICE")
USB_SIZE_GB=$((USB_SIZE / 1024 / 1024 / 1024))

echo "=========================================="
echo "Debian Live Custom Creation (Step 2)"
echo "Script $script_name version: $version"
echo "=========================================="
echo "Target device: $DEVICE"
echo "Device size: ${USB_SIZE_GB}GB"
echo "Custom Live system: $EXTRACT_DIR"
echo ""

# Display variant information if available
if [ -f "$VARIANT_INFO_FILE" ]; then
    echo "--- Variant Information ---"
    VARIANT_NAME=$(grep "^Variant Name:" "$VARIANT_INFO_FILE" | cut -d':' -f2- | xargs)
    if [ -n "$VARIANT_NAME" ]; then
        echo "Variant: $VARIANT_NAME"
    fi
    echo ""
fi

echo "WARNING: ALL DATA ON $DEVICE WILL BE ERASED!"
echo ""
read -p "Type 'YES' to continue: " confirm

if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "[RECOMPRESS] Persistence Setup"
echo "[RECOMPRESS] USB device size: ${USB_SIZE_GB}GB"
echo "[RECOMPRESS] Recommended persistence size: $((USB_SIZE_GB - 4))GB (leaving 4GB for Debian Live)"

read -p "[RECOMPRESS] Enter persistence partition size in GB (or press Enter for default): " PERSIST_SIZE
if [ -z "$PERSIST_SIZE" ]; then
    PERSIST_SIZE=$((USB_SIZE_GB - 4))
fi

# Define squashfs path
NEW_SQUASHFS="$SQUASHFS_WORK_DIR/filesystem-custom.squashfs"

# Check if squashfs has already been successfully created
if [ "$SQUASHFS_READY" = "true" ] && [ -f "$NEW_SQUASHFS" ]; then
    NEW_SIZE=$(du -h "$NEW_SQUASHFS" | cut -f1)
    echo ""
    echo "[RECOMPRESS] Squashfs already successfully created: $NEW_SQUASHFS"
    echo "[RECOMPRESS] Size: $NEW_SIZE"
    echo "[RECOMPRESS] Skipping compression step and proceeding to USB writing..."
    SKIP_COMPRESSION=true
elif [ -f "$NEW_SQUASHFS" ]; then
    # Squashfs exists but state not marked as ready (possibly incomplete)
    NEW_SIZE=$(du -h "$NEW_SQUASHFS" | cut -f1)
    echo ""
    echo "[RECOMPRESS] Found existing compressed squashfs (possibly incomplete): $NEW_SQUASHFS"
    echo "[RECOMPRESS] Size: $NEW_SIZE"
    read -p "[RECOMPRESS] Reuse existing squashfs? (Y/n): " reuse
    
    if [[ "$reuse" =~ ^[Nn]$ ]]; then
        echo "[RECOMPRESS] Will recompress from scratch..."
        SKIP_COMPRESSION=false
    else
        echo "[RECOMPRESS] Reusing existing squashfs..."
        SKIP_COMPRESSION=true
    fi
else
    SKIP_COMPRESSION=false
fi

if [ "$SKIP_COMPRESSION" = false ]; then
    # Cleanup chroot before recompression
    echo "[RECOMPRESS] Cleaning up chroot environment..."
    rm -f "$EXTRACT_DIR/etc/resolv.conf"
    rm -f "$EXTRACT_DIR/root/configure_system.sh"
    rm -rf "$EXTRACT_DIR/tmp/"*
    rm -rf "$EXTRACT_DIR/var/tmp/"*

    # Clean APT cache to reduce size
    echo "[RECOMPRESS] Cleaning package cache..."
    chroot "$EXTRACT_DIR" apt-get clean 2>/dev/null || true

    # Unmount chroot binds
    echo "[RECOMPRESS] Unmounting chroot bind mounts..."
    umount "$EXTRACT_DIR/sys" 2>/dev/null || true
    umount "$EXTRACT_DIR/proc" 2>/dev/null || true
    umount "$EXTRACT_DIR/dev/pts" 2>/dev/null || true
    umount "$EXTRACT_DIR/dev" 2>/dev/null || true

    # Backup existing custom squashfs if it exists and is different from source
    if [ -f "$NEW_SQUASHFS" ]; then
        # Check if this is an iterative modification (source was custom squashfs)
        if [ "$SOURCE_SQUASHFS" = "$NEW_SQUASHFS" ]; then
            # We're updating the custom squashfs, create a versioned backup
            BACKUP_CUSTOM="$VARIANT_DIR/filesystem-custom.squashfs.v$(date +%Y%m%d-%H%M%S)"
            echo "[RECOMPRESS] Creating versioned backup of existing custom squashfs..."
            echo "[RECOMPRESS] Backup: $BACKUP_CUSTOM"
            cp "$NEW_SQUASHFS" "$BACKUP_CUSTOM"
            chown "$ACTUAL_UID:$ACTUAL_GID" "$BACKUP_CUSTOM"
            chmod u+rw "$BACKUP_CUSTOM"
        else
            # Source was original, just remove the old custom squashfs
            echo "[RECOMPRESS] Removing old custom squashfs (starting from original)..."
            rm -f "$NEW_SQUASHFS"
        fi
    fi

    # Recompress squashfs
    echo "[RECOMPRESS] Recompressing squashfs (this may take 5-10 minutes)..."
    echo "[RECOMPRESS] Using xz compression for better compression ratio..."
    
    mksquashfs "$EXTRACT_DIR" "$NEW_SQUASHFS" \
        -comp xz \
        -Xbcj x86 \
        -b 1M \
        -no-xattrs \
        -noappend

    if [ ! -f "$NEW_SQUASHFS" ]; then
        echo "[RECOMPRESS] ERROR: Failed to create new squashfs"
        exit 1
    fi

    NEW_SIZE=$(du -h "$NEW_SQUASHFS" | cut -f1)
    ORIG_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "[RECOMPRESS] Original size: $ORIG_SIZE"
    echo "[RECOMPRESS] Custom size: $NEW_SIZE"
    
    # Fix ownership of squashfs file
    chown "$ACTUAL_UID:$ACTUAL_GID" "$NEW_SQUASHFS"
    chmod u+rw "$NEW_SQUASHFS"
    
    # Mark squashfs creation as complete
    echo "[RECOMPRESS] Marking squashfs creation as complete..."
    echo "SQUASHFS_READY=true" >> "$STATE_FILE"
    echo "NEW_SQUASHFS=\"$NEW_SQUASHFS\"" >> "$STATE_FILE"
    chown "$ACTUAL_UID:$ACTUAL_GID" "$STATE_FILE"
    chmod u+rw "$STATE_FILE"
    echo "[RECOMPRESS] State saved. If USB writing fails, you can retry without regenerating the squashfs."
fi

# Now partition and setup USB
echo ""
echo "[USB] Unmounting any mounted partitions on $DEVICE..."
umount ${DEVICE}* 2>/dev/null || true

echo "[USB] Wiping partition table..."
wipefs -a "$DEVICE"
dd if=/dev/zero of="$DEVICE" bs=1M count=10 status=none

echo "[USB] Creating new GPT partition table..."
parted -s "$DEVICE" mklabel gpt

echo "[USB] Creating EFI partition (512MB)..."
parted -s "$DEVICE" mkpart primary fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on

echo "[USB] Creating Debian Live partition (3GB)..."
parted -s "$DEVICE" mkpart primary ext4 513MiB 3585MiB

echo "[USB] Creating persistence partition (${PERSIST_SIZE}GB)..."
parted -s "$DEVICE" mkpart primary ext4 3585MiB $((3585 + PERSIST_SIZE * 1024))MiB

# Detect partition naming (sdX vs nvmeXnYpZ)
if [[ "$DEVICE" == *"nvme"* ]]; then
    PART1="${DEVICE}p1"
    PART2="${DEVICE}p2"
    PART3="${DEVICE}p3"
else
    PART1="${DEVICE}1"
    PART2="${DEVICE}2"
    PART3="${DEVICE}3"
fi

# Wait for partitions to appear
sleep 2
partprobe "$DEVICE"
sleep 2

echo "[USB] Formatting partitions..."
mkfs.vfat -F32 -n UEFI "$PART1"
mkfs.ext4 -L DEBIANLINUX "$PART2"
mkfs.ext4 -L persistence "$PART3"

echo "[USB] Mounting partitions..."
MOUNT_DIR=$(mktemp -d)
ISO_MOUNT=$(mktemp -d)
mkdir -p "$MOUNT_DIR/efi"
mkdir -p "$MOUNT_DIR/live"
mkdir -p "$MOUNT_DIR/persist"

mount "$ISO_FILE" "$ISO_MOUNT"
mount "$PART1" "$MOUNT_DIR/efi"
mount "$PART2" "$MOUNT_DIR/live"
mount "$PART3" "$MOUNT_DIR/persist"

echo "[USB] Copying Debian Live files from ISO to USB (excluding original squashfs)..."
rsync -a --info=progress2 --exclude='**/filesystem.squashfs' "$ISO_MOUNT/" "$MOUNT_DIR/live/"

echo "[USB] Installing custom squashfs..."
# Determine squashfs location from kernel path (e.g., if kernel is in live/vmlinuz, squashfs is in live/)
SQUASHFS_DIR=$(dirname "$VMLINUZ_REL")
TARGET_SQUASHFS="$MOUNT_DIR/live/$SQUASHFS_DIR/filesystem.squashfs"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$TARGET_SQUASHFS")"

# Copy custom squashfs directly
cp "$NEW_SQUASHFS" "$TARGET_SQUASHFS"
echo "[USB] Custom squashfs installed at: $SQUASHFS_DIR/filesystem.squashfs"

echo "[USB] Setting up EFI boot..."
mkdir -p "$MOUNT_DIR/efi/EFI/BOOT"
mkdir -p "$MOUNT_DIR/efi/boot/grub"

# Install GRUB for EFI boot
echo "[USB] Installing GRUB for EFI boot..."
grub-install --target=x86_64-efi --efi-directory="$MOUNT_DIR/efi" \
             --boot-directory="$MOUNT_DIR/efi/boot" --removable --no-nvram

echo "[USB] Found kernel: $VMLINUZ_REL"
echo "[USB] Found initrd: $INITRD_REL"

# Create GRUB configuration
echo "[USB] Creating GRUB configuration..."
cat > "$MOUNT_DIR/efi/boot/grub/grub.cfg" << GRUBEOF
set timeout=5
set default=0

menuentry 'Debian Live with Persistence (Custom System)' {
    search --no-floppy --set=root --label DEBIANLINUX
    linux /$VMLINUZ_REL boot=live components quiet splash persistence keyboard-layouts=de locales=de_DE.UTF-8
    initrd /$INITRD_REL
}

menuentry 'Debian Live (No Persistence)' {
    search --no-floppy --set=root --label DEBIANLINUX
    linux /$VMLINUZ_REL boot=live components quiet splash keyboard-layouts=de locales=de_DE.UTF-8
    initrd /$INITRD_REL
}

menuentry 'Reboot' {
    reboot
}

menuentry 'Shutdown' {
    halt
}
GRUBEOF

echo "[USB] Setting up persistence..."
echo "/ union" > "$MOUNT_DIR/persist/persistence.conf"

# Copy variant info file to persistence if it exists
if [ -f "$VARIANT_INFO_FILE" ]; then
    echo "[USB] Copying variant information to persistence..."
    cp "$VARIANT_INFO_FILE" "$MOUNT_DIR/persist/VARIANT_INFO.txt"
fi

echo "[USB] Cleaning up..."
sync
umount "$ISO_MOUNT"
umount "$MOUNT_DIR/efi"
umount "$MOUNT_DIR/live"
umount "$MOUNT_DIR/persist"
rmdir "$ISO_MOUNT"
rmdir "$MOUNT_DIR/efi"
rmdir "$MOUNT_DIR/live"
rmdir "$MOUNT_DIR/persist"
rmdir "$MOUNT_DIR"

# Cleanup work directory (but keep variant directory and squashfs file)
echo "[CLEANUP] Cleaning up temporary files..."
if [ -d "$EXTRACT_DIR" ]; then
    echo "[CLEANUP] Removing extract directory: $EXTRACT_DIR"
    rm -rf "$EXTRACT_DIR"
fi
# Only remove parent temp directory if it's not the variant dir and not the specified temp dir
EXTRACT_PARENT="$(dirname $EXTRACT_DIR)"
if [ -d "$EXTRACT_PARENT" ] && [ "$EXTRACT_PARENT" != "$VARIANT_DIR" ] && [ "$EXTRACT_PARENT" != "$SQUASHFS_WORK_DIR" ]; then
    echo "[CLEANUP] Removing temporary parent directory: $EXTRACT_PARENT"
    rm -rf "$EXTRACT_PARENT"
fi
echo "[CLEANUP] Keeping squashfs file for future use: $NEW_SQUASHFS"
rm -f "$STATE_FILE"

# Log successful USB creation to variant info file
if [ -f "$VARIANT_INFO_FILE" ]; then
    cat >> "$VARIANT_INFO_FILE" << LOGEOF
[$(date '+%Y-%m-%d %H:%M')] USB Media Created:
Device: $DEVICE
Partitions: $PART1 (EFI 512MB), $PART2 (Live 3GB), $PART3 (Persistence ${PERSIST_SIZE}GB)
Squashfs: $(basename "$NEW_SQUASHFS") ($(du -h "$NEW_SQUASHFS" | cut -f1))

LOGEOF
    chown "$ACTUAL_UID:$ACTUAL_GID" "$VARIANT_INFO_FILE"
    chmod u+rw "$VARIANT_INFO_FILE"
fi

echo ""
echo "=========================================="
echo "Custom Debian Live USB Complete!"
echo "=========================================="
echo ""
echo "Variant: $VARIANT_NAME"
echo ""

echo "Partitions created:"
echo "  $PART1 - EFI boot partition (512MB)"
echo "  $PART2 - Custom Debian Live system (3GB)"
echo "  $PART3 - Persistent storage (${PERSIST_SIZE}GB)"
echo ""
echo "Original squashfs backup: $BACKUP_FILE"
echo "Custom squashfs saved: $NEW_SQUASHFS"
echo "Variant directory: $VARIANT_DIR"

# Display variant info file location
if [ -f "$VARIANT_INFO_FILE" ]; then
    echo "Variant info: $VARIANT_INFO_FILE"
    echo "              (also copied to /live/persistence/VARIANT_INFO.txt on USB)"
fi

echo ""
echo "The USB key is ready to boot!"
echo "=========================================="
