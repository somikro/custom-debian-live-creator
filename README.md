# Custom Debian Live Creator

A robust, traceable, and flexible solution for creating and managing customized Debian Live USB systems with iterative modification support.

## Overview

This toolset consists of two bash scripts that work together to create customized Debian Live USB systems from official Debian Live ISOs. The solution supports iterative development, allowing you to refine your custom live system over multiple sessions while maintaining a complete history of all modifications.

## Features

- **Two-Step Workflow**: Separate extraction/customization and USB writing processes
- **Iterative Modification**: Continue from existing custom versions or start fresh from ISO
- **Variant Management**: Organize multiple custom variants with automatic tracking
- **Version History**: Automatic versioned backups of custom squashfs files
- **Modification Logging**: Track all customizations with timestamps in VARIANT_INFO.txt
- **USB Creation History**: Log all USB media creations with device details
- **Flexible Storage**: Support for RAM disk or disk-based working directories
- **Persistence Support**: Automatic setup of persistent storage partition
- **UEFI Boot**: Modern UEFI/GPT boot configuration with GRUB
- **File Ownership**: Proper ownership and permissions for all created files

## Requirements

- Debian/Ubuntu-based Linux system
- Root access (sudo)
- Required packages:
  ```bash
  sudo apt install squashfs-tools dosfstools grub-efi-amd64-bin grub2-common rsync
  ```
- Debian Live ISO file
- USB device (8GB+ recommended)

## Installation

Clone this repository:
```bash
git clone https://github.com/somikro/custom-debian-live-creator.git
cd custom-debian-live-creator
chmod +x create_custom_live_step1_extract.sh
chmod +x create_custom_live_step2_write.sh
```

## Usage

### Creating a New Custom Variant

**Step 1: Extract and Customize**
```bash
sudo ./create_custom_live_step1_extract.sh /path/to/debian-live-13.3.0-amd64-standard.iso
```

1. Enter a variant name (e.g., "ca-system", "dev-workstation")
2. Wait for ISO extraction (takes several minutes)
3. Enter chroot environment automatically
4. Customize the system:
   - Install packages: `apt-get update && apt-get install <packages>`
   - Configure settings
   - Run `/root/configure_system.sh` for helpful tips
5. Exit chroot: `exit`
6. Optionally add description of changes made

**Step 2: Write to USB**
```bash
sudo ./create_custom_live_step2_write.sh <variant-name> /dev/sdX
```

Example:
```bash
sudo ./create_custom_live_step2_write.sh ca-system /dev/sdb
```

⚠️ **WARNING**: This will ERASE ALL DATA on the target device!

The script will:
- Recompress the customized filesystem (5-10 minutes)
- Create GPT partition table with three partitions:
  - 512MB EFI boot partition
  - 3GB Debian Live system partition
  - Remaining space for persistent storage
- Install GRUB bootloader
- Copy custom squashfs and boot files

### Iterative Modification

#### Option 1: Via Existing Variant Name
```bash
sudo ./create_custom_live_step1_extract.sh /path/to/debian-live-13.3.0-amd64-standard.iso
```
1. Enter the existing variant name
2. Choose:
   - **Option 1**: Start fresh from ISO (delete and start over)
   - **Option 2**: Continue from custom squashfs (iterative modification)
   - **Option 3**: Abort
3. Make additional changes in chroot
4. Exit and add description of changes
5. Run step 2 to write updated version to USB

#### Option 2: Re-entering Active Session
```bash
sudo ./create_custom_live_step1_extract.sh
```
(No arguments - lists available variants)

1. Select variant to re-enter
2. For completed variants, instructions are shown
3. For active sessions, re-enters the chroot directly

### Using RAM Disk for Performance

For faster extraction, use a RAM disk:
```bash
# Create RAM disk
sudo mkdir -p /mnt/ramdisk
sudo mount -t tmpfs -o size=4G tmpfs /mnt/ramdisk

# Extract to RAM disk
sudo ./create_custom_live_step1_extract.sh /path/to/debian-live.iso /mnt/ramdisk
```

Similarly for step 2:
```bash
sudo ./create_custom_live_step2_write.sh <variant-name> /dev/sdX /mnt/ramdisk
```

## Variant Directory Structure

Each variant creates a directory with the following structure:

```
<variant-name>/
├── VARIANT_INFO.txt                           # Modification and creation history
├── filesystem.squashfs.original-<timestamp>   # Original ISO squashfs backup
├── filesystem-custom.squashfs                 # Current custom version
├── filesystem-custom.squashfs.v<timestamp>    # Versioned backups (when modified)
├── filesystem-custom.squashfs.backup-<timestamp> # Backup when starting fresh
└── work/                                      # Temporary extraction directory
    └── squashfs-root/                         # Extracted filesystem (during active session)
```

## VARIANT_INFO.txt Format

The variant info file tracks the complete history:

```
Custom Debian Live Variant Information
=======================================

Variant Name: ca-system
Created: 2026-01-28 13:15:05
Base ISO: debian-live-13.3.0-amd64-standard.iso

Customizations Log:
-------------------
[2026-01-28 13:15] Initial customization:
Configured German keyboard mapping
Added locales de_DE.UTF-8 and en_US.UTF-8
Installed vim, openssh-client, openssl

[2026-01-28 14:30] Additional changes:
Updated all packages to latest versions
Added custom SSL certificates

[2026-01-28 15:45] USB Media Created:
Device: /dev/sdb
Partitions: /dev/sdb1 (EFI 512MB), /dev/sdb2 (Live 3GB), /dev/sdb3 (Persistence 28GB)
Squashfs: filesystem-custom.squashfs (1.2G)
```

## Boot Configuration

The USB system includes two boot options:

1. **Debian Live with Persistence** (default)
   - Full read/write persistence
   - German keyboard and locales
   - Changes are saved to the persistence partition

2. **Debian Live (No Persistence)**
   - Read-only live system
   - No changes are saved
   - Fresh system on each boot

## Workflow Examples

### Example 1: Creating a CA Certificate System

```bash
# Step 1: Create and customize
sudo ./create_custom_live_step1_extract.sh debian-live-13.3.0-amd64-standard.iso

# In chroot:
apt-get update
apt-get install -y openssl easy-rsa yubikey-manager
# Configure system...
exit

# Step 2: Write to USB
sudo ./create_custom_live_step2_write.sh ca-system /dev/sdb
```

### Example 2: Updating an Existing Variant

```bash
# Modify existing variant
sudo ./create_custom_live_step1_extract.sh debian-live-13.3.0-amd64-standard.iso

# Enter: ca-system
# Choose: Option 2 (Continue from custom)

# In chroot:
apt-get update && apt-get upgrade -y
# Add more tools...
exit

# Write updated version
sudo ./create_custom_live_step2_write.sh ca-system /dev/sdc
```

## Technical Details

### Compression
- Uses `xz` compression with x86 BCJ filter
- Block size: 1MB
- No extended attributes preserved
- Typical compression ratio: 40-50%

### Partitioning
- GPT partition table for UEFI compatibility
- EFI System Partition (FAT32, 512MB)
- Live system partition (ext4, 3GB)
- Persistence partition (ext4, remaining space)

### Security Considerations
- All files created with proper user ownership
- Read/write permissions set for owner
- Original ISO backup preserved
- Versioned backups for rollback capability

## Troubleshooting

### "File exists" error during extraction
The script now automatically cleans up old extraction directories. If issues persist, manually remove the work directory:
```bash
sudo rm -rf <variant-dir>/work
```

### Insufficient space
- Use a larger USB device (16GB+ recommended for large customizations)
- Use RAM disk for temporary storage
- Clean up old versioned backups if needed

### USB won't boot
- Verify UEFI boot is enabled in BIOS
- Try different USB port
- Check that Secure Boot is disabled
- Verify ISO integrity

### Permission errors
Scripts require root access. Always use `sudo`.

## Version History

- **v1.1** (2026-01-28)
  - Added iterative workflow support
  - Added variant detection for completed variants
  - Added automatic extraction directory cleanup
  - Added USB creation logging to VARIANT_INFO.txt
  - Added versioned backup of custom squashfs
  - Improved user prompts and error messages
  - Added file ownership and permission fixes

- **v1.0** (2026-01-28)
  - Initial release
  - Basic extract and write functionality

## License

This project is licensed under Creative Commons.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Author

Created by somikro, 2026

## Acknowledgments

- Based on Debian Live system
- Developed with assistance from GitHub Copilot
