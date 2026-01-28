#!/bin/bash
# create_custom_live_step1_extract.sh
# Extract Debian Live squashfs from ISO and prepare for customization
# The script asks the user for a variant name and creates a variant directory
# It mounts the ISO and extracts the squashfs filesystem to a working directory at /tmp
# and then it enters a chroot for interactive customization
# When exiting chroot, the user can save notes about changes made
# A state file is created for use in step 2 script which contains these details:
# - WORK_DIR: Temporary working directory in /tmp where extraction is done
# - EXTRACT_DIR: root directory of the extracted squashfs filesystem
# - BACKUP_FILE: Path to the original squashfs backup
# - SOURCE_SQUASHFS: Path to the squashfs used as source (original or custom)
# - ISO_FILE: Path to the original ISO file
# - VMLINUZ_REL: Relative path to kernel in ISO
# - INITRD_REL: Relative path to initrd in ISO
# - VARIANT_INFO_FILE: Path to the variant info text file
# - VARIANT_NAME: Name of the custom variant
# - VARIANT_DIR: Directory of the custom variant
# This script must be run as root (sudo)
#
# Iterative Workflow:
# - If a filesystem-custom.squashfs already exists in the variant directory,
#   you can choose to either start fresh from the original ISO or continue
#   modifying the existing custom version for iterative refinement
# - When step 2 recompresses, old versions are automatically backed up with timestamps
# 
# To modify a completed variant:
# 1. Run this script with the original ISO: sudo ./script.sh debian-live.iso
# 2. Enter the existing variant name (will ask to overwrite)
# 3. Choose option 2 to load the existing custom squashfs
# 4. Make your changes in the chroot
# 5. Run step 2 to write to USB (old version is backed up automatically)
#
# Usage: sudo ./create_custom_live_step1_extract.sh path/to/debian-live.iso [work-dir]
#        Example: sudo ./create_custom_live_step1_extract.sh debian-live-13.0.0-amd64-standard.iso
#        Example: sudo ./create_custom_live_step1_extract.sh debian-live-13.0.0-amd64-standard.iso /mnt/ramdisk
#        Optional work-dir: Directory for extraction (e.g., RAM disk)
#        If not specified, variant directory is used
# Or without arguments to re-enter existing chroot:
#        sudo ./create_custom_live_step1_extract.sh

script_name=$(basename "$0")
version="1.1 by somikro 2026"
startTS=$(date +%s.%N)
# Version history:
# 1.1 - Added iterative workflow: can now reload and modify existing custom squashfs
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if we're re-entering an existing chroot (no arguments)
if [ $# -eq 0 ]; then
    # List available variants (both active and completed)
    echo "=========================================="
    echo "Available Variants:"
    echo "=========================================="
    
    VARIANTS_FOUND=false
    ACTIVE_VARIANTS=()
    COMPLETED_VARIANTS=()
    
    for variant_dir in "$SCRIPT_DIR"/*/; do
        if [ -d "$variant_dir" ]; then
            VARIANT_NAME=$(basename "$variant_dir")
            # Check if this is a valid variant directory
            # Valid if it has either: state file (active) OR custom/original squashfs files (completed)
            if [ -f "$variant_dir/.custom_live_state" ]; then
                echo "  - $VARIANT_NAME (active chroot session)"
                ACTIVE_VARIANTS+=("$VARIANT_NAME")
                VARIANTS_FOUND=true
            elif [ -f "$variant_dir/filesystem-custom.squashfs" ] || ls "$variant_dir"/filesystem.squashfs.original-* &>/dev/null; then
                echo "  - $VARIANT_NAME (completed)"
                COMPLETED_VARIANTS+=("$VARIANT_NAME")
                VARIANTS_FOUND=true
            fi
        fi
    done
    
    if [ "$VARIANTS_FOUND" = false ]; then
        echo "No variants found. Run with ISO file argument to create a new variant."
        echo "Usage: $0 <debian-live-iso> [work-dir]"
        exit 1
    fi
    
    echo ""
    read -p "Enter variant name to re-enter or modify: " SELECTED_VARIANT
    
    VARIANT_DIR="$SCRIPT_DIR/$SELECTED_VARIANT"
    STATE_FILE="$VARIANT_DIR/.custom_live_state"
    
    if [ ! -d "$VARIANT_DIR" ]; then
        echo "ERROR: Variant '$SELECTED_VARIANT' not found"
        exit 1
    fi
    
    # Check if this is an active chroot session or a completed variant
    if [ ! -f "$STATE_FILE" ]; then
        # No state file - this is a completed variant
        echo ""
        echo "=========================================="
        echo "Completed Variant Selected"
        echo "=========================================="
        echo "Variant '$SELECTED_VARIANT' has been completed (no active chroot session)."
        echo ""
        
        # Extract ISO filename from VARIANT_INFO.txt if available
        BASE_ISO=""
        if [ -f "$VARIANT_DIR/VARIANT_INFO.txt" ]; then
            BASE_ISO=$(grep "^Base ISO:" "$VARIANT_DIR/VARIANT_INFO.txt" | cut -d':' -f2- | xargs)
        fi
        
        echo "To modify this variant:"
        if [ -n "$BASE_ISO" ]; then
            echo "  1. Locate the original ISO file: $BASE_ISO"
            echo "  2. Run: sudo $0 <path-to/$BASE_ISO>"
        else
            echo "  1. Find the original ISO file used to create it"
            echo "  2. Run: sudo $0 <path-to-iso>"
        fi
        echo "  3. Enter '$SELECTED_VARIANT' as the variant name"
        echo "  4. Choose option 2 to continue from the existing custom squashfs"
        echo ""
        
        # Show what's in the variant directory
        if [ -f "$VARIANT_DIR/filesystem-custom.squashfs" ]; then
            CUSTOM_SIZE=$(du -h "$VARIANT_DIR/filesystem-custom.squashfs" | cut -f1)
            echo "Available: filesystem-custom.squashfs ($CUSTOM_SIZE)"
        fi
        
        if ls "$VARIANT_DIR"/filesystem.squashfs.original-* &>/dev/null; then
            echo "Available: filesystem.squashfs.original-* (backup from ISO)"
        fi
        
        echo ""
        exit 0
    fi
    
    # Active chroot session exists
    source "$STATE_FILE"
    
    if [ ! -d "$EXTRACT_DIR" ] || [ ! -d "$EXTRACT_DIR/root" ]; then
        echo "ERROR: Extract directory not found or invalid: $EXTRACT_DIR"
        echo "Please run with ISO file argument to create a new extraction."
        exit 1
    fi
    
    echo "=========================================="
    echo "Re-entering Existing Chroot Session"
    echo "=========================================="
    echo "Variant: $SELECTED_VARIANT"
    echo "Extract directory: $EXTRACT_DIR"
    echo ""
    
    # Re-mount chroot binds if not already mounted
    mountpoint -q "$EXTRACT_DIR/dev" || mount --bind /dev "$EXTRACT_DIR/dev"
    mountpoint -q "$EXTRACT_DIR/dev/pts" || mount --bind /dev/pts "$EXTRACT_DIR/dev/pts"
    mountpoint -q "$EXTRACT_DIR/proc" || mount --bind /proc "$EXTRACT_DIR/proc"
    mountpoint -q "$EXTRACT_DIR/sys" || mount --bind /sys "$EXTRACT_DIR/sys"
    
    # Update resolv.conf
    cp /etc/resolv.conf "$EXTRACT_DIR/etc/resolv.conf"
    
    echo "Entering chroot..."
    echo ""
    chroot "$EXTRACT_DIR" /bin/bash
    
    echo ""
    echo "[EXTRACT] Exited from chroot"
    
    # Ask if user wants to add to description
    echo ""
    read -p "[EXTRACT] Add notes about changes made? (y/N): " add_notes
    
    if [[ "$add_notes" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Enter description of additional changes (end with empty line):"
        ADDITIONAL_DESC=""
        while IFS= read -r line; do
            [ -z "$line" ] && break
            ADDITIONAL_DESC="${ADDITIONAL_DESC}${line}"$'\n'
        done
        
        # Append to variant info file
        cat >> "$VARIANT_INFO_FILE" << INFOEOF
[$(date '+%Y-%m-%d %H:%M')] Additional changes:
$ADDITIONAL_DESC

INFOEOF
        
        echo "[EXTRACT] Variant info updated"
    fi
    
    echo "[EXTRACT] Chroot binds are still mounted"
    echo "[EXTRACT] Run create_custom_live_step2_write.sh $SELECTED_VARIANT /dev/sdX to complete the process"
    echo "[EXTRACT] Or run this script again (without arguments) to re-enter chroot"
    exit 0
fi

# Fresh extraction with ISO argument
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <debian-live-iso> [work-dir]"
    echo "Example: $0 debian-live-13.0.0-amd64-standard.iso"
    echo "Example: $0 debian-live-13.0.0-amd64-standard.iso /mnt/ramdisk"
    echo ""
    echo "Optional work-dir: Directory for extraction (e.g., RAM disk)"
    echo "If not specified, variant directory is used"
    echo ""
    echo "Or run without arguments to re-enter existing chroot session."
    exit 1
fi

ISO_FILE=$1
WORK_DIR_PARAM="${2:-}"

# Ask for variant name at the beginning
echo "====================================================="
echo "Custom Debian Live Variant Creation"
echo "Version: $version"
echo "====================================================="
echo ""
read -p "Enter a name for this custom Live variant (e.g., 'ca-system', 'dev-workstation'): " VARIANT_NAME

# Validate variant name (no spaces, special chars)
if [[ ! "$VARIANT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Variant name can only contain letters, numbers, hyphens, and underscores"
    exit 1
fi

# Create variant directory
VARIANT_DIR="$SCRIPT_DIR/$VARIANT_NAME"
CUSTOM_SQUASHFS="$VARIANT_DIR/filesystem-custom.squashfs"
CONTINUE_FROM_CUSTOM=false

if [ -d "$VARIANT_DIR" ]; then
    echo ""
    echo "WARNING: Variant '$VARIANT_NAME' already exists."
    
    # Check if custom squashfs exists
    if [ -f "$CUSTOM_SQUASHFS" ]; then
        CUSTOM_SIZE=$(du -h "$CUSTOM_SQUASHFS" | cut -f1)
        echo ""
        echo "Existing custom squashfs found: $CUSTOM_SIZE"
        echo ""
        echo "What would you like to do?"
        echo "  1) Start FRESH from ISO (delete existing variant and start over)"
        echo "  2) CONTINUE from existing custom squashfs (iterative modification)"
        echo "  3) ABORT (cancel operation)"
        echo ""
        read -p "Enter choice (1, 2, or 3): " variant_choice
        
        case $variant_choice in
            1)
                echo "Starting fresh - removing existing variant directory..."
                rm -rf "$VARIANT_DIR"
                ;;
            2)
                echo "Continuing from existing custom squashfs..."
                CONTINUE_FROM_CUSTOM=true
                ;;
            3)
                echo "Aborted."
                exit 0
                ;;
            *)
                echo "ERROR: Invalid choice. Aborting."
                exit 1
                ;;
        esac
    else
        # No custom squashfs, just ask to overwrite
        read -p "Overwrite existing variant? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
        rm -rf "$VARIANT_DIR"
    fi
fi

if [ "$CONTINUE_FROM_CUSTOM" = false ]; then
    mkdir -p "$VARIANT_DIR"
    chown "$ACTUAL_UID:$ACTUAL_GID" "$VARIANT_DIR"
    chmod u+rwx "$VARIANT_DIR"
    echo "[EXTRACT] Created variant directory: $VARIANT_DIR"
else
    echo "[EXTRACT] Using existing variant directory: $VARIANT_DIR"
fi
echo ""

# Validate input
if [ ! -f "$ISO_FILE" ]; then
    echo "ERROR: ISO file $ISO_FILE not found"
    exit 1
fi

# Check for required tools
for cmd in unsquashfs mount; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: $cmd not found."
        [ "$cmd" = "unsquashfs" ] && echo "Install with: sudo apt install squashfs-tools"
        exit 1
    fi
done

echo "====================================================="
echo "Debian Live Custom Creation (Step 1)"
echo "Version: $version"
echo "====================================================="
echo "Source ISO: $ISO_FILE"
echo ""

# Determine working directory for extraction
if [ -n "$WORK_DIR_PARAM" ]; then
    if [ ! -d "$WORK_DIR_PARAM" ]; then
        echo "ERROR: Specified work directory does not exist: $WORK_DIR_PARAM"
        exit 1
    fi
    WORK_DIR=$(mktemp -d -p "$WORK_DIR_PARAM" custom-live-XXXXXX)
    echo "Using custom work directory: $WORK_DIR_PARAM"
else
    WORK_DIR="$VARIANT_DIR/work"
    mkdir -p "$WORK_DIR"
    chown "$ACTUAL_UID:$ACTUAL_GID" "$WORK_DIR"
    chmod u+rw "$WORK_DIR"
    echo "Using variant directory for extraction: $WORK_DIR"
fi

ISO_MOUNT="$WORK_DIR/iso-mount"
EXTRACT_DIR="$WORK_DIR/squashfs-root"

echo "[EXTRACT] Working directory: $WORK_DIR"
echo "[EXTRACT] Mounting ISO..."
mkdir -p "$ISO_MOUNT"
mount -o loop "$ISO_FILE" "$ISO_MOUNT"

# Find the squashfs file
SQUASHFS_FILE=$(find "$ISO_MOUNT" -name "filesystem.squashfs" -type f | head -1)

if [ -z "$SQUASHFS_FILE" ]; then
    echo "[EXTRACT] ERROR: Could not find filesystem.squashfs in ISO"
    umount "$ISO_MOUNT"
    rm -rf "$WORK_DIR"
    exit 1
fi

echo "[EXTRACT] Found squashfs: $SQUASHFS_FILE"
SQUASHFS_SIZE=$(du -h "$SQUASHFS_FILE" | cut -f1)
echo "[EXTRACT] Original size: $SQUASHFS_SIZE"

# Store backup in variant directory
BACKUP_FILE="$VARIANT_DIR/filesystem.squashfs.original-$(date +%Y%m%d-%H%M%S)"

# Create backup
echo "[EXTRACT] Creating backup: $BACKUP_FILE"
cp "$SQUASHFS_FILE" "$BACKUP_FILE"
chown "$ACTUAL_UID:$ACTUAL_GID" "$BACKUP_FILE"
chmod u+rw "$BACKUP_FILE"

# Find kernel and initrd in ISO for later
VMLINUZ=$(find "$ISO_MOUNT" -name "vmlinuz*" -type f | head -1)
INITRD=$(find "$ISO_MOUNT" -name "initrd*" -type f | head -1)

if [ -z "$VMLINUZ" ] || [ -z "$INITRD" ]; then
    echo "[EXTRACT] ERROR: Could not find kernel or initrd in ISO"
    umount "$ISO_MOUNT"
    rm -rf "$WORK_DIR"
    exit 1
fi

# Get relative paths from ISO mount point
VMLINUZ_REL=${VMLINUZ#$ISO_MOUNT/}
INITRD_REL=${INITRD#$ISO_MOUNT/}

echo "[EXTRACT] Found kernel: $VMLINUZ_REL"
echo "[EXTRACT] Found initrd: $INITRD_REL"

# Unmount ISO
umount "$ISO_MOUNT"
echo "[EXTRACT] ISO unmounted"

# Determine source squashfs based on earlier choice
SOURCE_SQUASHFS="$BACKUP_FILE"

if [ "$CONTINUE_FROM_CUSTOM" = true ]; then
    # User already chose to continue from custom squashfs
    if [ -f "$CUSTOM_SQUASHFS" ]; then
        SOURCE_SQUASHFS="$CUSTOM_SQUASHFS"
        CUSTOM_SIZE=$(du -h "$CUSTOM_SQUASHFS" | cut -f1)
        echo ""
        echo "=========================================="
        echo "Using Existing Custom Squashfs"
        echo "=========================================="
        echo "Source: $CUSTOM_SQUASHFS"
        echo "Size: $CUSTOM_SIZE"
        echo ""
    else
        echo "ERROR: Custom squashfs not found: $CUSTOM_SQUASHFS"
        exit 1
    fi
else
    # Starting fresh or no custom squashfs existed
    echo "[EXTRACT] Using original squashfs from ISO"
fi

# Clean up any existing extraction directory
if [ -d "$EXTRACT_DIR" ]; then
    echo "[EXTRACT] Cleaning up old extraction directory..."
    # Unmount any existing bind mounts first
    umount "$EXTRACT_DIR/sys" 2>/dev/null || true
    umount "$EXTRACT_DIR/proc" 2>/dev/null || true
    umount "$EXTRACT_DIR/dev/pts" 2>/dev/null || true
    umount "$EXTRACT_DIR/dev" 2>/dev/null || true
    rm -rf "$EXTRACT_DIR"
fi

# Extract squashfs from chosen source
echo "[EXTRACT] Extracting squashfs (this may take several minutes)..."
echo "[EXTRACT] Source: $SOURCE_SQUASHFS"
unsquashfs -d "$EXTRACT_DIR" "$SOURCE_SQUASHFS"

if [ ! -d "$EXTRACT_DIR" ]; then
    echo "[EXTRACT] ERROR: Extraction failed"
    rm -rf "$WORK_DIR"
    exit 1
fi

echo "[EXTRACT] Extraction complete"

# Prepare chroot environment
echo "[EXTRACT] Preparing chroot environment..."
mount --bind /dev "$EXTRACT_DIR/dev"
mount --bind /dev/pts "$EXTRACT_DIR/dev/pts"
mount --bind /proc "$EXTRACT_DIR/proc"
mount --bind /sys "$EXTRACT_DIR/sys"

# Copy DNS resolution
cp /etc/resolv.conf "$EXTRACT_DIR/etc/resolv.conf"

# Create helper script for inside chroot
cat > "$EXTRACT_DIR/root/configure_system.sh" << 'HELPEREOF'
#!/bin/bash
# Helper script for configuring the Live system

echo "=========================================="
echo "Live System Configuration Helper"
echo "=========================================="
echo ""
echo "You are now in a chroot of the extracted Live system."
echo "You can install packages and configure the system."
echo ""
echo "Recommended steps:"
echo ""
echo "1. Fix APT sources for network access:"
echo "   cat > /etc/apt/sources.list << 'EOF'"
echo "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware"
echo "deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware"
echo "deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware"
echo "EOF"
echo ""
echo "2. Update package list:"
echo "   apt-get update"
echo ""
echo "3. Install and configure locales FIRST (to avoid LC_CTYPE errors):"
echo "   apt-get install -y locales"
echo "   dpkg-reconfigure locales"
echo "   (Select en_US.UTF-8 and de_DE.UTF-8, set en_US.UTF-8 as default)"
echo "   export LANG=en_US.UTF-8"
echo "   export LC_ALL=en_US.UTF-8"
echo ""
echo "4. Install keyboard packages:"
echo "   apt-get install -y console-setup console-data keyboard-configuration kbd"
echo ""
echo "5. Configure keyboard interactively:"
echo "   dpkg-reconfigure keyboard-configuration"
echo "   (Select Generic 105-key, German, German, defaults)"
echo ""
echo "6. Configure console font (for text-mode display):"
echo "   dpkg-reconfigure console-setup"
echo "   (UTF-8, Guess optimal, Terminus, 14x28 or 16x32)"
echo ""
echo "7. Install additional packages as needed:"
echo "   apt-get install -y vim openssh-client openssl"
echo ""
echo "8. Configure locale settings for English language + German formats:"
echo "   update-locale LANG=en_US.UTF-8 LC_TIME=de_DE.UTF-8 LC_NUMERIC=de_DE.UTF-8"
echo ""
echo "9. When done, exit the chroot:"
echo "   exit"
echo ""
echo "=========================================="
HELPEREOF

chmod +x "$EXTRACT_DIR/root/configure_system.sh"

# Save state for step 2 script
ISO_ABS_PATH=$(realpath "$ISO_FILE")
VARIANT_INFO_FILE="$VARIANT_DIR/VARIANT_INFO.txt"
STATE_FILE="$VARIANT_DIR/.custom_live_state"
cat > "$STATE_FILE" << EOF
WORK_DIR=$WORK_DIR
EXTRACT_DIR=$EXTRACT_DIR
BACKUP_FILE=$BACKUP_FILE
SOURCE_SQUASHFS=$SOURCE_SQUASHFS
ISO_FILE=$ISO_ABS_PATH
VMLINUZ_REL=$VMLINUZ_REL
INITRD_REL=$INITRD_REL
VARIANT_INFO_FILE=$VARIANT_INFO_FILE
VARIANT_NAME=$VARIANT_NAME
VARIANT_DIR=$VARIANT_DIR
EOF
chown "$ACTUAL_UID:$ACTUAL_GID" "$STATE_FILE"
chmod u+rw "$STATE_FILE"

echo ""
echo "=========================================="
echo "Ready for Interactive Configuration"
echo "=========================================="
echo ""
echo "Variant: $VARIANT_NAME"
echo "Variant directory: $VARIANT_DIR"
echo "State saved to: $STATE_FILE"
echo "Backup saved to: $BACKUP_FILE"
echo "Extract directory: $EXTRACT_DIR"
echo ""
echo "Starting interactive chroot session..."
echo "Run /root/configure_system.sh for configuration tips"
echo ""
echo "When you're done configuring, type 'exit' to leave chroot"
echo "Then run: sudo ./create_custom_live_step2_write.sh $VARIANT_NAME /dev/sdX"
echo ""
echo "=========================================="
echo ""

# Enter chroot
chroot "$EXTRACT_DIR" /bin/bash

echo ""
echo "[EXTRACT] Exited from chroot"

# Collect variant information
if [ ! -f "$VARIANT_INFO_FILE" ]; then
    # First time - create new variant info file
    echo ""
    echo "=========================================="
    echo "Custom Live Variant Information"
    echo "=========================================="
    echo ""
    echo "Variant Name: $VARIANT_NAME"
    echo ""
    echo "Enter a description of customizations made (end with empty line):"
    VARIANT_DESC=""
    while IFS= read -r line; do
        [ -z "$line" ] && break
        VARIANT_DESC="${VARIANT_DESC}${line}"$'\n'
    done
    
    # Create variant info file
    cat > "$VARIANT_INFO_FILE" << INFOEOF
Custom Debian Live Variant Information
=======================================

Variant Name: $VARIANT_NAME
Created: $(date '+%Y-%m-%d %H:%M:%S')
Base ISO: $(basename "$ISO_FILE")

Customizations Log:
-------------------
[$(date '+%Y-%m-%d %H:%M')] Initial customization:
$VARIANT_DESC

INFOEOF
    
    chown "$ACTUAL_UID:$ACTUAL_GID" "$VARIANT_INFO_FILE"
    chmod u+rw "$VARIANT_INFO_FILE"
    echo ""
    echo "[EXTRACT] Variant info saved to: $VARIANT_INFO_FILE"
else
    # Variant info file exists - add to it
    echo ""
    read -p "[EXTRACT] Add notes about changes made? (y/N): " add_notes
    
    if [[ "$add_notes" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Enter description of changes (end with empty line):"
        ADDITIONAL_DESC=""
        while IFS= read -r line; do
            [ -z "$line" ] && break
            ADDITIONAL_DESC="${ADDITIONAL_DESC}${line}"$'\n'
        done
        
        # Append to variant info file
        cat >> "$VARIANT_INFO_FILE" << INFOEOF
[$(date '+%Y-%m-%d %H:%M')] Additional changes:
$ADDITIONAL_DESC

INFOEOF
        
        echo "[EXTRACT] Variant info updated"
    fi
    echo "[EXTRACT] Variant info file: $VARIANT_INFO_FILE"
fi

echo "[EXTRACT] Chroot binds are still mounted"
echo "[EXTRACT] Run create_custom_live_step2_write.sh $VARIANT_NAME /dev/sdX to complete the process"
echo "[EXTRACT] Or run this script again without arguments to re-enter chroot"
