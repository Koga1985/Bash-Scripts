#!/usr/bin/env bash
#
# LUKS Encrypt & Mount (Enterprise-ready)
# - Idempotent, documented, and safe by default (dry-run).
# - Use --apply to make actual changes. Supports --verbose and --yes.
#
# IMPORTANT:
# - Running this script WILL ERASE DATA on the chosen block device when applied.
# - Test in a safe environment before running in production.

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Defaults and configuration (customize before running when needed)
################################################################################

# Operational flags (overridable via CLI)
DRY_RUN=true
VERBOSE=false
FORCE=false

# Paths and names
LOG_FILE="/var/log/luks_encrypt.log"
BACKUP_DIR="/var/tmp/luks-backup-$(date +%Y%m%d%H%M%S)"
MOUNT_DIR="/mnt/encrypted"
MAPPER_NAME="luks"   # /dev/mapper/<MAPPER_NAME>

# Files to back up (fstab/crypttab if used)
FILES_TO_BACKUP=("/etc/fstab" "/etc/crypttab")

################################################################################
# Helper functions
################################################################################

log() {
  local level="INFO"
  if [[ "$1" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]]; then
    level="$1"; shift
  fi
  printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
  mkdir -p "$(dirname "$LOG_FILE")" || true
  printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

debug() { [[ "$VERBOSE" == true ]] && log DEBUG "$*"; }

error_exit() {
  log ERROR "$*"
  exit 1
}

run_cmd() {
  if [[ "$VERBOSE" == true ]]; then
    log DEBUG "+ $*"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log INFO "DRY-RUN: $*"
  else
    eval "$*"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "$FORCE" == true ]]; then
    return 0
  fi
  read -r -p "$prompt [yes/no]: " response
  if [[ "$response" != "yes" ]]; then
    return 1
  fi
  return 0
}

backup_file_if_exists() {
  local src="$1"
  if [[ -e "$src" ]]; then
    run_cmd "mkdir -p '$BACKUP_DIR' && cp -a '$src' '$BACKUP_DIR/'"
    log INFO "Backed up $src -> $BACKUP_DIR/"
  else
    debug "No file to backup: $src"
  fi
}

################################################################################
# Pre-flight checks
################################################################################

trap 'error_exit "Unexpected error on line $LINENO"' ERR

if [[ $EUID -ne 0 ]]; then
  error_exit "This script must be run as root. Use sudo or run as root."
fi

# Required commands
REQUIRED_CMDS=(cryptsetup mkfs.ext4 mount blkid)
for c in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$c" &>/dev/null; then
    error_exit "Required command '$c' not found. Install it before running this script."
  fi
done

################################################################################
# CLI args
################################################################################

usage() {
  cat <<-USAGE
Usage: $0 [--apply] [--yes] [--verbose] [--backup-dir DIR]

Defaults to dry-run. Options:
  --apply           Apply changes (disable dry-run)
  --yes, -y         Skip confirmations
  --verbose, -v     Enable verbose debug output
  --backup-dir DIR  Use custom backup directory
  --help, -h        Show this help
USAGE
}

while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --yes|-y) FORCE=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log WARN "Unknown option: $1"; usage; exit 2 ;;
  esac
done

log INFO "LUKS Encryption script starting"
log INFO "Dry-run: $DRY_RUN, Verbose: $VERBOSE, Force: $FORCE"

################################################################################
# Operator input: Device and options
################################################################################

read -r -p "Enter the block device to encrypt (e.g., /dev/sdX): " BLOCK_DEVICE
if [[ ! -b "$BLOCK_DEVICE" ]]; then
  error_exit "Block device $BLOCK_DEVICE does not exist or is not a block device."
fi

# Guard: ensure device is not mounted
if mount | grep -q "^$BLOCK_DEVICE" || mount | grep -q "/dev/mapper/$MAPPER_NAME"; then
  error_exit "Device $BLOCK_DEVICE or /dev/mapper/$MAPPER_NAME is already mounted. Unmount first."
fi

log INFO "Selected block device: $BLOCK_DEVICE"

################################################################################
# Safety: check for existing LUKS, prompt for re-encrypt
################################################################################

if cryptsetup isLuks "$BLOCK_DEVICE" &>/dev/null; then
  log WARN "Block device $BLOCK_DEVICE already appears to be LUKS-encrypted."
  if ! confirm "Do you want to reformat/re-encrypt it and destroy existing data?"; then
    error_exit "Operator aborted (device already encrypted)."
  fi
fi

if ! confirm "WARNING: This will ERASE ALL DATA on $BLOCK_DEVICE. Proceed?"; then
  error_exit "Operator cancelled the operation."
fi

################################################################################
# Backup critical files (fstab/crypttab) and create backup directory
################################################################################

log INFO "Preparing backup directory: $BACKUP_DIR"
run_cmd "mkdir -p '$BACKUP_DIR' && chmod 700 '$BACKUP_DIR'"
for f in "${FILES_TO_BACKUP[@]}"; do
  backup_file_if_exists "$f"
done

################################################################################
# Gather passphrase securely
################################################################################

read -s -p "Enter passphrase for LUKS (will not be echoed): " passphrase
echo
read -s -p "Confirm passphrase: " passphrase_confirm
echo
if [[ "$passphrase" != "$passphrase_confirm" ]]; then
  error_exit "Passphrases do not match. Aborting."
fi
unset passphrase_confirm

################################################################################
# Perform encryption, mapping, format, and mount
################################################################################

ENCRYPT_CMD="echo -n \"$passphrase\" | cryptsetup luksFormat --type luks2 --key-file=- '$BLOCK_DEVICE'"
run_cmd "$ENCRYPT_CMD"

# Open the LUKS container
OPEN_CMD="echo -n \"$passphrase\" | cryptsetup open --type luks2 --key-file=- '$BLOCK_DEVICE' '$MAPPER_NAME'"
run_cmd "$OPEN_CMD"

MAPPED_DEVICE="/dev/mapper/$MAPPER_NAME"

# Format if not already formatted as ext4
if blkid "$MAPPED_DEVICE" 2>/dev/null | grep -q ext4; then
  log INFO "Mapped device $MAPPED_DEVICE already has ext4 filesystem. Skipping mkfs."
else
  run_cmd "mkfs.ext4 -F '$MAPPED_DEVICE'"
fi

# Ensure mount dir exists and mount
run_cmd "mkdir -p '$MOUNT_DIR' && chmod 750 '$MOUNT_DIR'"
if mount | grep -q " $MOUNT_DIR "; then
  log INFO "Mount point $MOUNT_DIR already in use. Skipping mount."
else
  run_cmd "mount '$MAPPED_DEVICE' '$MOUNT_DIR'"
  log INFO "Mounted $MAPPED_DEVICE at $MOUNT_DIR"
fi

################################################################################
# Optional: Persist mapping in /etc/crypttab and /etc/fstab (prompt operator)
################################################################################

if confirm "Would you like to add entries to /etc/crypttab and /etc/fstab to mount on boot?"; then
  CRYPTTAB_ENTRY="$MAPPER_NAME $BLOCK_DEVICE none luks"
  FSTAB_ENTRY="$MAPPED_DEVICE $MOUNT_DIR ext4 defaults 0 2"
  log INFO "Will append to /etc/crypttab: $CRYPTTAB_ENTRY"
  log INFO "Will append to /etc/fstab: $FSTAB_ENTRY"
  if confirm "Apply these changes to /etc/crypttab and /etc/fstab now?"; then
    run_cmd "cp -a /etc/crypttab '$BACKUP_DIR/crypttab.bak' || true"
    run_cmd "cp -a /etc/fstab '$BACKUP_DIR/fstab.bak' || true"
    run_cmd "bash -c 'echo \"$CRYPTTAB_ENTRY\" >> /etc/crypttab'"
    run_cmd "bash -c 'echo \"$FSTAB_ENTRY\" >> /etc/fstab'"
    log INFO "Appended crypttab/fstab entries (backups in $BACKUP_DIR)."
  else
    log INFO "Skipped writing to crypttab/fstab."
  fi
fi

################################################################################
# Final summary and cleanup
################################################################################

log INFO "LUKS encryption flow complete (or simulated)."
log INFO "Summary:"
log INFO " - Block device: $BLOCK_DEVICE"
log INFO " - Mapper device: $MAPPED_DEVICE"
log INFO " - Mounted at: $MOUNT_DIR"
log INFO " - Backup directory: $BACKUP_DIR"
log INFO " - Log file: $LOG_FILE"

log INFO "To unmount and close the encrypted device:"
log INFO "  sudo umount $MOUNT_DIR"
log INFO "  sudo cryptsetup close $MAPPER_NAME"

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Dry-run was enabled. Re-run with --apply to perform changes."
fi

log INFO "Script finished."
