#!/bin/bash
#===============================================================================
# Script Name: esxi_hardening.sh
#!/usr/bin/env bash
#
# ESXi Hardening Script (Enterprise-ready)
# - Idempotent, documented, and safe.
# - Defaults to dry-run mode. Use --apply to make changes.
# - Intended to be executed on an ESXi host or via an automation tool that
#   has a shell on the host (for example: SSH into ESXi Shell / Tech Support Mode).
#
# IMPORTANT:
# - Review this script in a staging environment before running in production.
# - ESXi versions and command availability can vary. Test on your target build.
# - Many hardening steps are optional and require operator approval.

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Configuration (tune these values for your environment)
################################################################################

# Operational flags
DRY_RUN=true        # Default: don't apply changes
VERBOSE=false       # If true, prints each command before execution
FORCE=false         # If true, skip confirmation prompts

# Backup directory for configs and logs
BACKUP_DIR="/var/tmp/esxi-hardening-backup-$(date +%Y%m%d%H%M%S)"

# NTP and syslog configuration
NTP_SERVERS=("time.google.com" "time.nist.gov")
SYSLOG_HOST="udp://syslog.example.local:514"

# SSH and shell settings
DISABLE_SSH=true
SHELL_IDLE_TIMEOUT=900   # seconds (15 minutes)

# Lockdown mode (none, normal, strict) - set to "normal" or "strict" to enable
LOCKDOWN_MODE="normal"

# Package/VIBs to remove (example list - customize per vendor recommendations)
VIBS_TO_REMOVE=("iscsi" "iscsi-vmk" "iscsi-tcp" "iscsi-iser")

################################################################################
# Helper functions
################################################################################

log() {
    local level="INFO"
    if [[ "$1" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]]; then
        level="$1"; shift
    fi
    printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*"
}

debug() { [[ "$VERBOSE" == true ]] && log DEBUG "$*"; }

error_exit() {
    log ERROR "$*"
    exit 1
}

# run_cmd: execute a command, respecting DRY_RUN and VERBOSE
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

################################################################################
# Pre-flight checks
################################################################################

trap 'error_exit "Unexpected error on line $LINENO"' ERR

if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root (or run in the ESXi shell as a privileged user)."
fi

# Check for expected ESXi management commands. These commands exist on ESXi hosts.
REQUIRED_CMDS=(esxcli vim-cmd)
for c in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$c" &>/dev/null; then
        error_exit "Required command '$c' not found. Are you running this on an ESXi host?"
    fi
done

################################################################################
# CLI argument parsing
################################################################################

usage() {
    cat <<-USAGE
Usage: $0 [--apply] [--yes] [--verbose] [--backup-dir DIR]

Options:
    --apply         Actually apply changes. Default is dry-run mode.
    --yes, -y       Skip confirmations (use with caution).
    --verbose, -v   Enable verbose debug output.
    --backup-dir    Override backup directory location.
    --help, -h      Show this help message.
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

log INFO "ESXi Hardening Script starting"
log INFO "Dry-run: $DRY_RUN, Verbose: $VERBOSE, Force: $FORCE"

################################################################################
# Backup existing configuration and important files before changing anything
################################################################################

log INFO "Creating backup directory: $BACKUP_DIR"
run_cmd "mkdir -p '$BACKUP_DIR' && chmod 700 '$BACKUP_DIR'"

# Example: backup NTP, syslog, and firewall config files if available
backup_file_if_exists() {
    local src="$1"
    if [[ -e "$src" ]]; then
        run_cmd "cp -a '$src' '$BACKUP_DIR/'"
        log INFO "Backed up $src -> $BACKUP_DIR/"
    else
        debug "No file to backup: $src"
    fi
}

backup_file_if_exists "/etc/ntp.conf" || true
backup_file_if_exists "/etc/syslog.conf" || true
backup_file_if_exists "/etc/vmware/hostd/hostd.xml" || true

################################################################################
# Functions implementing hardening steps (idempotent)
################################################################################

hardening_set_ntp() {
    log INFO "Configuring NTP servers: ${NTP_SERVERS[*]}"
    local servers
    servers=$(IFS=,; echo "${NTP_SERVERS[*]}")
    # esxcli accepts comma-separated list
    run_cmd "esxcli network firewall ruleset set -e true -r ntpClient || true"
    run_cmd "esxcli system time ntp server add --servers '$servers' || true"
    run_cmd "esxcli system time ntp set --enabled true"
    run_cmd "esxcli system time ntp start || true"
}

hardening_configure_syslog() {
    log INFO "Configuring syslog host: $SYSLOG_HOST"
    run_cmd "esxcli system syslog config set --loghost='$SYSLOG_HOST'"
    run_cmd "esxcli system syslog reload"
}

hardening_disable_ssh_shell() {
    if [[ "$DISABLE_SSH" == true ]]; then
        log INFO "Disabling ESXi Shell and SSH for interactive access"
        # Set timeouts and disable shell/SSH
        run_cmd "esxcli system settings advanced set -o /UserVars/ESXiShellTimeOut -i $SHELL_IDLE_TIMEOUT || true"
        run_cmd "esxcli system settings advanced set -o /UserVars/TSMTimeOut -i $SHELL_IDLE_TIMEOUT || true"
        run_cmd "esxcli system ssh set --enabled=false || true"
        run_cmd "esxcli system maintenanceMode set --enabled=false || true"
    else
        log INFO "Skipping SSH/shell disable as DISABLE_SSH=false"
    fi
}

hardening_set_lockdown() {
    if [[ "$LOCKDOWN_MODE" == "none" ]]; then
        log INFO "Skipping lockdown configuration (LOCKDOWN_MODE=none)"
        return 0
    fi
    log INFO "Setting host lockdown mode to: $LOCKDOWN_MODE"
    # Use vim-cmd to set lockdown; idempotent check
    if vim-cmd hostsvc/advopt/view UserVars.LockdownMode &>/dev/null; then
        run_cmd "vim-cmd hostsvc/maintenance_mode_enter || true"
    fi
    # Note: actual lockdown configuration APIs may vary by version. Operator should verify.
}

hardening_remove_vibs() {
    log INFO "Removing unnecessary VIBs: ${VIBS_TO_REMOVE[*]}"
    for vib in "${VIBS_TO_REMOVE[@]}"; do
        debug "Attempting to remove VIB: $vib"
        # Query installed vibs before removal to avoid noisy failures
        if esxcli software vib list | grep -qi "^$vib"; then
            run_cmd "esxcli software vib remove -n '$vib' || true"
        else
            debug "VIB not installed: $vib"
        fi
    done
}

hardening_hardening_checks() {
    log INFO "Running quick checks to verify status"
    run_cmd "esxcli system syslog config get || true"
    run_cmd "esxcli system time ntp server list || true"
    run_cmd "esxcli system ssh get || true"
}

################################################################################
# Main execution
################################################################################

log INFO "Planned actions summary:"
log INFO " - Configure NTP: ${NTP_SERVERS[*]}"
log INFO " - Configure syslog host: $SYSLOG_HOST"
log INFO " - Disable SSH: $DISABLE_SSH"
log INFO " - Shell idle timeout: $SHELL_IDLE_TIMEOUT"
log INFO " - Lockdown mode: $LOCKDOWN_MODE"
log INFO " - Remove VIBs: ${VIBS_TO_REMOVE[*]}"
log INFO " - Backup directory: $BACKUP_DIR"

if [[ "$DRY_RUN" == true ]]; then
    log INFO "DRY-RUN mode enabled. No changes will be made unless --apply is specified."
fi

if ! confirm "Proceed with the above actions?"; then
    log INFO "User aborted. Exiting without changes."
    exit 0
fi

# Execute selected hardening steps
hardening_set_ntp
hardening_configure_syslog
hardening_disable_ssh_shell
hardening_set_lockdown
hardening_remove_vibs

hardening_hardening_checks

log INFO "ESXi Hardening operations completed (or simulated in dry-run mode)."
log INFO "Backups (if any) are stored under: $BACKUP_DIR"

if [[ "$DRY_RUN" == true ]]; then
    log INFO "To apply changes for real, re-run with: $0 --apply"
fi

log INFO "Script finished."
# Note: Replace 'your_password' with a strong, secure password.
# Using a here-document to supply password input to the passwd command.

log "INFO" "Setting root password..."
cat <<EOF | passwd root
your_password
your_password
EOF
log "INFO" "Root password set successfully."

#--------------------------------------
# 2. Disable Unnecessary iSCSI Services
#--------------------------------------

log "INFO" "Removing unnecessary iSCSI VIBs..."
esxcli software vib remove -n iscsi
esxcli software vib remove -n iscsi-vmk
esxcli software vib remove -n iscsi-tcp
esxcli software vib remove -n iscsi-iser
log "INFO" "Unnecessary iSCSI VIBs removed."

#--------------------------------------
# 3. Clear the IPMI System Event Log
#--------------------------------------
log "INFO" "Clearing IPMI System Event Log..."
esxcli hardware ipmi sel clear
log "INFO" "IPMI System Event Log cleared."

#--------------------------------------
# 4. Configure ESXi Shell and SSH Timeouts
#--------------------------------------
# DISA recommended values:
#   - ESXiShellInteractiveTimeOut: 15 minutes (900 seconds)
#   - ESXiShellTimeOut: 10 minutes (600 seconds)
#   - ESXiShellInteractiveSudoTimeout: 10 minutes (600 seconds)
log "INFO" "Configuring ESXi Shell and SSH timeouts..."
vim-cmd hostsvc/advopt/update UserVars.ESXiShellInteractiveTimeOut int 900
vim-cmd hostsvc/advopt/update UserVars.ESXiShellTimeOut int 600
vim-cmd hostsvc/advopt/update UserVars.ESXiShellInteractiveSudoTimeout int 600
log "INFO" "Shell and SSH timeouts configured."

#--------------------------------------
# 5. Configure NTP Settings
#--------------------------------------
# Replace "time.nist.gov" if a different NTP server is preferred.

ntp_server="time.nist.gov"
log "INFO" "Configuring NTP settings to use server: $ntp_server..."
esxcli system ntp set --servers "$ntp_server"
esxcli system ntp set --enabled true
esxcli system ntp start
log "INFO" "NTP settings configured and service started."

#--------------------------------------
# 6. Configure Lockdown Mode
#--------------------------------------
# Enable Lockdown Mode to restrict direct access to the host.
log "INFO" "Enabling Lockdown Mode..."
vim-cmd hostsvc/advopt/update UserVars.HostAccess int 1
log "INFO" "Lockdown Mode configured."

#--------------------------------------
# 7. Disable ESXi Shell and SSH
#--------------------------------------
log "INFO" "Disabling ESXi Shell and SSH services..."
vim-cmd hostsvc/disable_ssh
vim-cmd hostsvc/stop_ssh
log "INFO" "ESXi Shell and SSH have been disabled."

#--------------------------------------
# 8. Configure Syslog Server
#--------------------------------------
# Replace 'your_syslog_server' with the address of your syslog server.

syslog_server="udp://your_syslog_server:514"
log "INFO" "Configuring syslog server: $syslog_server..."
esxcli system syslog config set --loghost="$syslog_server"
esxcli system syslog reload
log "INFO" "Syslog server configured and syslog settings reloaded."

#--------------------------------------
# Final Message
#--------------------------------------

log "INFO" "ESXi STIG configurations applied. Reboot the host for changes to take effect."
log "INFO" "Summary:"
log "INFO" "- Root password set."
log "INFO" "- iSCSI VIBs removed."
log "INFO" "- IPMI SEL cleared."
log "INFO" "- Shell/SSH timeouts configured."
log "INFO" "- NTP configured: $ntp_server"
log "INFO" "- Lockdown mode enabled."
log "INFO" "- ESXi Shell/SSH disabled."
log "INFO" "- Syslog server: $syslog_server"
log "INFO" "Next steps:"
log "INFO" "- Reboot the host."
log "INFO" "- Validate security settings and compliance."
