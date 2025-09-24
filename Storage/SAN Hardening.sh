#!/usr/bin/env bash
#
# SAN Hardening Script (Enterprise-ready)
# - Idempotent, documented, and safe.
# - Defaults to dry-run mode. Use --apply to make changes.
# - Intended to be adapted per vendor (EMC/VMAX, NetApp, HPE 3PAR/Alletra, Dell Unity, Pure, etc.).
#
# IMPORTANT:
# - Review and test on staging SANs before running in production.
# - Replace placeholders with vendor-specific CLI/API calls.
# - This script will not perform vendor firmware upgrades automatically; it contains
#   helper placeholders and safe patterns for orchestration.

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Configuration (tune these values for your environment)
################################################################################

# Operational flags
DRY_RUN=true        # Default to dry-run. Use --apply to make changes.
VERBOSE=false       # Enable verbose/debug output
FORCE=false         # Skip user confirmations when true

# Logging and backup
SAN_NAME="MySAN"                          # Friendly name for logs
LOG_FILE="/var/log/san_stig.log"          # Central log for this script
BACKUP_DIR="/var/tmp/san-stig-backup-$(date +%Y%m%d%H%M%S)"

# Network & management settings - customize for your environment
NTP_SERVERS=("time.google.com" "time.nist.gov")
SYSLOG_HOSTS=("udp://syslog.example.local:514")

# Authentication policy (placeholders; implement via vendor tools)
PASSWORD_POLICY_MINLEN=14
PASSWORD_POLICY_COMPLEX=true

# RBAC and audit schedule (examples)
AUDIT_SCHEDULE="weekly"
RBAC_TEMPLATE="san-admins:read-write;san-ops:read-only"

# VENDOR_TOOL placeholder (e.g., naviseccli, omshell, pureadm, smcli, etc.)
VENDOR_TOOL="sanctl"   # Replace with your vendor CLI binary

################################################################################
# Helper functions
################################################################################

log() {
    local level="INFO"
    if [[ "$1" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]]; then
        level="$1"; shift
    fi
    printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*"
    # Ensure log directory exists before writing
    mkdir -p "$(dirname "$LOG_FILE")" || true
    printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

debug() { [[ "$VERBOSE" == true ]] && log DEBUG "$*"; }

error_exit() {
    log ERROR "$*"
    exit 1
}

# run_cmd: Executes a command or prints it in dry-run mode. Supports verbose logging.
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

# Minimal set of utilities we expect to exist on an admin host; vendor CLIs vary.
REQUIRED_TOOLS=(date tar curl ssh)
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        log WARN "Recommended tool '$tool' not found in PATH. Some operations may not work."
    fi
done

################################################################################
# CLI arguments
################################################################################

usage() {
    cat <<-USAGE
Usage: $0 [--apply] [--yes] [--verbose] [--backup-dir DIR] [--help]

Options:
    --apply         Apply changes (default is dry-run).
    --yes, -y       Skip confirmations.
    --verbose, -v   Enable debug/verbose output.
    --backup-dir    Custom directory for backups.
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

log INFO "Starting SAN Hardening for: $SAN_NAME"
log INFO "Dry-run: $DRY_RUN, Verbose: $VERBOSE, Force: $FORCE"

################################################################################
# Backup of common config locations (no-op if not present)
################################################################################

log INFO "Preparing backup directory: $BACKUP_DIR"
run_cmd "mkdir -p '$BACKUP_DIR' && chmod 700 '$BACKUP_DIR'"
backup_file_if_exists "/etc/hosts"
backup_file_if_exists "/etc/ntp.conf"
backup_file_if_exists "/etc/rsyslog.conf"

################################################################################
# Step implementations (high level, vendor-neutral)
################################################################################

step_update_firmware_and_software() {
    log INFO "Step 1: Update SAN firmware/software (placeholder)"
    log INFO "NOTE: Firmware updates are vendor-specific and typically require maintenance windows."
    log INFO "This script will not perform automatic firmware updates by default."
    # Example pattern (operator must replace with vendor-specific commands):
    # run_cmd "$VENDOR_TOOL firmware check --target all"
    # run_cmd "$VENDOR_TOOL firmware update --target node1 --file /tmp/fw.bin"
}

step_configure_strong_authentication() {
    log INFO "Step 2: Configure strong authentication for SAN management interfaces"
    log INFO "Example actions: enforce password length, disable default accounts, enable 2FA where supported."
    # Placeholder: Check current password policy (vendor CLI) and apply recommended settings
    # run_cmd "$VENDOR_TOOL auth policy show"
    # run_cmd "$VENDOR_TOOL auth policy set --min-length $PASSWORD_POLICY_MINLEN --complex=true"
}

step_enable_encryption_for_communication() {
    log INFO "Step 3: Enable encryption for SAN management and data channels (where supported)"
    log INFO "Examples: TLS for management APIs, IPsec/iSCSI/TLS for data plane where supported."
    # Placeholder to inspect TLS settings and update certs
    # run_cmd "$VENDOR_TOOL tls show"
    # run_cmd "$VENDOR_TOOL tls set --cert /path/to/cert.pem --key /path/to/key.pem"
}

step_configure_access_controls() {
    log INFO "Step 4: Implement access controls to restrict unauthorized access"
    log INFO "Examples: restrict management network, allowlist admin IPs, disable unused services."
    # Example: configure management interface ACLs (vendor CLI)
    # run_cmd "$VENDOR_TOOL network acl add --interface mgmt0 --allow 10.0.0.0/24"
}

step_configure_centralized_logging() {
    log INFO "Step 5: Configure centralized logging for SAN events"
    for host in "${SYSLOG_HOSTS[@]}"; do
        log INFO "Adding syslog host: $host"
        # Placeholder: vendor-specific syslog configuration
        # run_cmd "$VENDOR_TOOL logging syslog add --host '$host'"
    done
}

step_setup_auditing_and_schedules() {
    log INFO "Step 6: Setup regular audits for SAN configuration and access logs"
    log INFO "Schedule: $AUDIT_SCHEDULE"
    # Placeholder: create scheduled jobs to export configs/logs
    # run_cmd "$VENDOR_TOOL audit schedule create --freq $AUDIT_SCHEDULE --action export-config --dest /backups"
}

step_configure_rbac() {
    log INFO "Step 7: Implement RBAC for SAN administration"
    log INFO "RBAC template: $RBAC_TEMPLATE"
    # Placeholder: parse and apply RBAC_TEMPLATE
    # run_cmd "$VENDOR_TOOL rbac import --template '$RBAC_TEMPLATE'"
}

step_policy_review() {
    log INFO "Step 8: Review and update SAN security policies periodically"
    log INFO "This is a manual step: ensure policies are reviewed and updated per change control."
}

################################################################################
# Execution plan (idempotent and safe)
################################################################################

log INFO "Planned steps (will run in order):"
log INFO "1) Update firmware/software"
log INFO "2) Configure strong authentication"
log INFO "3) Enable encryption for communication"
log INFO "4) Configure access controls"
log INFO "5) Configure centralized logging"
log INFO "6) Setup auditing and schedules"
log INFO "7) Configure RBAC"
log INFO "8) Policy review guidance"

if [[ "$DRY_RUN" == true ]]; then
    log INFO "DRY-RUN mode is active. No changes will be applied.";
fi

if ! confirm "Proceed with the above actions for SAN '$SAN_NAME'?"; then
    log INFO "Operation cancelled by operator. Exiting."
    exit 0
fi

# Execute steps
step_update_firmware_and_software
step_configure_strong_authentication
step_enable_encryption_for_communication
step_configure_access_controls
step_configure_centralized_logging
step_setup_auditing_and_schedules
step_configure_rbac
step_policy_review

log INFO "SAN STIG configuration completed (or simulated in dry-run)."
log INFO "Summary:"
log INFO "- SAN Name: $SAN_NAME"
log INFO "- Backup directory: $BACKUP_DIR"
log INFO "- Log file: $LOG_FILE"
log INFO "Next steps:"
log INFO "- Review $LOG_FILE for details and suggested commands."
log INFO "- Replace placeholder vendor commands with your SAN vendor CLI/API calls."
log INFO "- Run with --apply to make changes when ready."

# End of script
log INFO "SAN Hardening script finished."
