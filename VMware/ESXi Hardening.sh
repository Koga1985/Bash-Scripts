#!/bin/bash
#===============================================================================
# Script Name: esxi_hardening.sh
#
# DESCRIPTION:
#   This script applies several security hardening configurations to an ESXi host
#   according to recommended STIG guidelines. The actions performed include:
#     - Setting the root password
#     - Removing unnecessary iSCSI VIBs
#     - Clearing the IPMI System Event Log
#     - Configuring ESXi Shell and SSH timeouts
#     - Configuring NTP settings
#     - Enabling Lockdown Mode
#     - Disabling ESXi Shell and SSH
#     - Configuring a remote syslog server
#
# PREREQUISITES:
#   - This script must be run on an ESXi host with appropriate privileges.
#   - Update placeholders (e.g., "your_password", "your_syslog_server") before running.
#
# USAGE:
#   Run this script as root. A reboot is required after execution for some changes to 
#   take effect.
#
# AUTHOR:         Your Name or Organization
# CREATED DATE:   2025-04-14
# VERSION:        1.0
#===============================================================================

# Exit immediately if a command exits with a non-zero status.

set -e

# Trap unexpected errors
trap 'log "ERROR" "Unexpected error occurred on line $LINENO."; exit 1' ERR

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo or run as root." >&2
    exit 1
fi

# Check for required tools
REQUIRED_TOOLS=(esxcli vim-cmd passwd)
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        log "ERROR" "Required tool '$tool' not found. Please install it before running this script."
        exit 1
    fi
done

#--------------------------------------
# Logging Function
#--------------------------------------
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message"
}

#--------------------------------------
# 1. Set the Root Password
#--------------------------------------
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
