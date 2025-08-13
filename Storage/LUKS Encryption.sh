#!/bin/bash
#===============================================================================
# Script Name: encrypt_and_mount.sh
# Description:
#   This script encrypts a given block device using LUKS (luks2), formats the 
#   encrypted device with an ext4 filesystem, and mounts it at a designated location.
# 
#   The script performs the following steps:
#     1. Checks that required utilities (cryptsetup, mkfs.ext4, mount) are installed.
#     2. Verifies that the script is run as root.
#     3. Prompts the user for a block device to encrypt and validates its existence.
#     4. Confirms that the user wants to proceed (warning that all data will be erased).
#     5. Prompts for a passphrase and confirmation, aborting if they do not match.
#     6. Encrypts the block device using LUKS with the provided passphrase.
#     7. Opens the LUKS container to create a mapper device.
#     8. Formats the newly opened device with an ext4 filesystem.
#     9. Mounts the encrypted device to a predefined mount directory.
#    10. Provides instructions to unmount and close the encrypted device.
#
# Prerequisites:
#   - This script must be run as root.
#   - Required utilities: cryptsetup, mkfs.ext4, mount.
#   - Make sure you have a backup of any important data. All data on the block device
#     will be erased.
#
# Author: Your Name or Organization
# Date: 2025-04-14
# Version: 1.1
#===============================================================================

# Exit immediately if a command fails, if an undefined variable is used, or if any command in a pipeline fails.

set -euo pipefail
IFS=$'\n\t'

# Trap unexpected errors
trap 'error_exit "Unexpected error occurred on line $LINENO."' ERR

#----------------------------------------------
# Pre-flight Checks
#----------------------------------------------

# Ensure the script is running as root.
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

# Check for required commands.
for cmd in cryptsetup mkfs.ext4 mount; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] Required command '$cmd' not found. Please install it before running this script." >&2
        exit 1
    fi
done

#----------------------------------------------
# Global Logging Functions
#----------------------------------------------
function log() {
  # Outputs a timestamped info message to stdout and appends to the log file.
  local message="$1"
  echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $message"
}

function error_exit() {
  # Outputs a timestamped error message to stderr, logs the error, and exits.
  local message="$1"
  echo -e "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $message" >&2
  exit 1
}

#----------------------------------------------
# Variables
#----------------------------------------------
# Customize variables as needed
BLOCK_DEVICE=""             # Will be set based on user input.
MOUNT_DIR="/mnt/encrypted"  # Mount point for the encrypted device.
LOG_FILE="/var/log/san_stig.log"  # Logging file path (adjust as needed)

#----------------------------------------------
# 1. Prompt for Block Device and Validate
#----------------------------------------------

read -p "Enter the block device to encrypt (e.g., /dev/sdX): " BLOCK_DEVICE
if [[ ! -b "$BLOCK_DEVICE" ]]; then
  error_exit "Block device $BLOCK_DEVICE does not exist or is not a valid block device."
fi
log "Block device $BLOCK_DEVICE found."

# Check if device is already encrypted
if cryptsetup isLuks "$BLOCK_DEVICE" &>/dev/null; then
  log "Block device $BLOCK_DEVICE is already encrypted with LUKS."
  read -p "Do you want to re-encrypt and erase all data? (yes/no): " reencrypt
  if [[ "$reencrypt" != "yes" ]]; then
    error_exit "Operation aborted by user."
  fi
fi

#----------------------------------------------
# 2. Confirmation: Warning about Data Loss
#----------------------------------------------

read -p "WARNING: This will erase all data on $BLOCK_DEVICE. Are you sure you want to continue? (yes/no): " confirmation
if [[ "$confirmation" != "yes" ]]; then
  error_exit "Operation aborted by user."
fi
log "User confirmed to proceed with encryption."

#----------------------------------------------
# 3. Prompt for Passphrase and Validation
#----------------------------------------------

read -s -p "Enter the passphrase for encryption: " passphrase
echo    # Newline after password input.
read -s -p "Confirm the passphrase: " confirmPassphrase
echo    # Newline after confirmation input.
if [[ "$passphrase" != "$confirmPassphrase" ]]; then
  error_exit "Passphrases do not match. Aborting."
fi
log "Passphrase confirmed."

#----------------------------------------------
# 4. Encrypt the Block Device using LUKS
#----------------------------------------------

log "Encrypting $BLOCK_DEVICE with LUKS..."
if ! echo -n "$passphrase" | cryptsetup luksFormat --type luks2 "$BLOCK_DEVICE"; then
  error_exit "Failed to encrypt $BLOCK_DEVICE."
fi
log "Encryption of $BLOCK_DEVICE completed."

#----------------------------------------------
# 5. Open the LUKS Encrypted Device
#----------------------------------------------

log "Opening the encrypted device..."
if [[ -e /dev/mapper/luks ]]; then
  log "/dev/mapper/luks already exists. Skipping open."
else
  if ! echo -n "$passphrase" | cryptsetup open "$BLOCK_DEVICE" luks; then
      error_exit "Failed to open the encrypted device."
  fi
  log "Encrypted device opened successfully."
fi

#----------------------------------------------
# 6. Format the Encrypted Device with ext4 Filesystem
#----------------------------------------------

log "Formatting the encrypted device (/dev/mapper/luks) with ext4 filesystem..."
if blkid /dev/mapper/luks | grep -q ext4; then
  log "Encrypted device already formatted with ext4. Skipping format."
else
  if ! mkfs.ext4 /dev/mapper/luks; then
      error_exit "Failed to format the encrypted device."
  fi
  log "Filesystem formatted successfully."
fi

#----------------------------------------------
# 7. Mount the Encrypted Device
#----------------------------------------------

log "Mounting the encrypted device at $MOUNT_DIR..."
if [[ ! -d "$MOUNT_DIR" ]]; then
  if ! mkdir -p "$MOUNT_DIR"; then
      error_exit "Failed to create mount directory $MOUNT_DIR."
  fi
fi
if mount | grep -q "$MOUNT_DIR"; then
  log "Encrypted device already mounted at $MOUNT_DIR."
else
  if ! mount /dev/mapper/luks "$MOUNT_DIR"; then
      error_exit "Failed to mount the encrypted device."
  fi
  log "Encrypted device mounted at $MOUNT_DIR."
fi

#----------------------------------------------
# Final Instructions and Success Message
#----------------------------------------------

log "LUKS encryption has been successfully applied to $BLOCK_DEVICE and mounted at $MOUNT_DIR."
log "Summary:"
log "- Block device: $BLOCK_DEVICE"
log "- Mount point: $MOUNT_DIR"
log "- Mapper device: /dev/mapper/luks"
log "Next steps:"
log "- To unmount: sudo umount $MOUNT_DIR"
log "- To close:   sudo cryptsetup close luks"
