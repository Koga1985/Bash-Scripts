#!/usr/bin/env bash
#
# OpenShift Client Install & Project Bootstrap (Enterprise-ready)
# - Idempotent, documented, and safe by default (dry-run).
# - Use --apply to perform changes. Supports --verbose and --yes to skip prompts.
#
# Notes:
# - This script installs or updates the OpenShift client (oc) and optionally
#   creates a project and deploys a sample app. Replace placeholders for production use.

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Defaults and configuration (tune for your environment)
################################################################################

# Operational flags
DRY_RUN=true
VERBOSE=false
FORCE=false

# Primary settings
OCP_VERSION="4.12.0"
INSTALL_DIR="/opt/openshift"
PROJECT_NAME="myproject"
SAMPLE_APP_IMAGE="openshift/deployment-example"
LOG_FILE="/var/log/openshift_install.log"
BACKUP_DIR="/var/tmp/openshift-backup-$(date +%Y%m%d%H%M%S)"

# Location to copy 'oc' for system-wide usage
OC_SYMLINK="/usr/local/bin/oc"

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

REQUIRED_TOOLS=(wget tar)
for t in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$t" &>/dev/null; then
    error_exit "Required tool '$t' not found. Install it and retry."
  fi
done

################################################################################
# CLI args
################################################################################

usage() {
  cat <<-USAGE
Usage: $0 [--apply] [--yes] [--verbose] [--install-dir DIR] [--version VER]

Defaults to dry-run. Options:
  --apply             Apply changes (disable dry-run)
  --yes, -y           Skip confirmations
  --verbose, -v       Enable verbose debug output
  --install-dir DIR   Override OpenShift client install directory
  --version VER       Specify OpenShift client version to install
  --help, -h          Show this help message
USAGE
}

while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --yes|-y) FORCE=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --version) OCP_VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log WARN "Unknown option: $1"; usage; exit 2 ;;
  esac
done

log INFO "OpenShift client installer starting"
log INFO "Dry-run: $DRY_RUN, Verbose: $VERBOSE, Force: $FORCE"

################################################################################
# Backup existing oc and PATH settings
################################################################################

log INFO "Preparing backup directory: $BACKUP_DIR"
run_cmd "mkdir -p '$BACKUP_DIR' && chmod 700 '$BACKUP_DIR'"
backup_file_if_exists "$OC_SYMLINK"

################################################################################
# Ensure install directory exists and is writable
################################################################################

log INFO "Ensuring install directory: $INSTALL_DIR"
run_cmd "mkdir -p '$INSTALL_DIR' && chmod 755 '$INSTALL_DIR'"

################################################################################
# Determine existing oc installation and version (if any)
################################################################################

INSTALLED_OC=""
INSTALLED_VERSION=""
if command -v oc &>/dev/null; then
  INSTALLED_OC=$(command -v oc)
  if oc version --client &>/dev/null; then
    INSTALLED_VERSION=$(oc version --client | sed -n 's/.*Client Version:\s*//p' | tr -d ',')
  fi
  log INFO "Found existing 'oc' at: ${INSTALLED_OC} (version: ${INSTALLED_VERSION:-unknown})"
fi

################################################################################
# Download and extract oc if needed
################################################################################

OC_TARBALL="/tmp/openshift-client-linux-${OCP_VERSION}.tar.gz"
OC_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux-${OCP_VERSION}.tar.gz"

if [[ -z "$INSTALLED_VERSION" || "$INSTALLED_VERSION" != "$OCP_VERSION" ]]; then
  log INFO "Downloading OpenShift client version $OCP_VERSION from $OC_DOWNLOAD_URL"
  run_cmd "wget -q -O '$OC_TARBALL' '$OC_DOWNLOAD_URL'"
  log INFO "Extracting tarball to $INSTALL_DIR"
  run_cmd "tar -xzf '$OC_TARBALL' -C '$INSTALL_DIR'"

  # Ensure executable installed and optionally symlink into /usr/local/bin
  if [[ -x "$INSTALL_DIR/oc" ]]; then
    log INFO "oc binary extracted at $INSTALL_DIR/oc"
    if [[ ! -e "$OC_SYMLINK" ]]; then
      log INFO "Creating symlink $OC_SYMLINK -> $INSTALL_DIR/oc"
      run_cmd "ln -s '$INSTALL_DIR/oc' '$OC_SYMLINK'"
    else
      log INFO "$OC_SYMLINK already exists; skipping symlink creation."
    fi
  else
    error_exit "oc binary not found after extraction. Check tarball contents."
  fi
else
  log INFO "Required oc version $OCP_VERSION already installed. Skipping download."
fi

################################################################################
# Login to OpenShift cluster as cluster admin (if possible)
################################################################################

log INFO "Verifying OpenShift cluster access"
if command -v oc &>/dev/null; then
  if oc whoami &>/dev/null; then
    log INFO "Already logged in as: $(oc whoami)"
  else
    log INFO "Attempting to login as 'system:admin' (requires local cluster admin credentials)"
    if ! oc login -u system:admin &>/dev/null; then
      log WARN "Failed to login as system:admin. Cluster may be unreachable or credentials unavailable. Skipping cluster operations."
      SKIP_CLUSTER_OPS=true
    else
      SKIP_CLUSTER_OPS=false
      log INFO "Successfully logged in as system:admin"
    fi
  fi
else
  error_exit "oc binary not available; cannot perform cluster operations."
fi

################################################################################
# Create project and deploy sample app (cluster operations)
################################################################################

if [[ "${SKIP_CLUSTER_OPS:-true}" == true ]]; then
  log WARN "Skipping project creation and app deployment due to lack of cluster access."
else
  log INFO "Creating OpenShift project: $PROJECT_NAME"
  if oc get project "$PROJECT_NAME" &>/dev/null; then
    log INFO "Project $PROJECT_NAME already exists."
  else
    run_cmd "oc new-project '$PROJECT_NAME'"
    log INFO "Project '$PROJECT_NAME' created."
  fi

  log INFO "Deploying sample app: $SAMPLE_APP_IMAGE"
  if oc get all -n "$PROJECT_NAME" | grep -q "$SAMPLE_APP_IMAGE"; then
    log INFO "Sample app already present in project $PROJECT_NAME."
  else
    run_cmd "oc new-app '$SAMPLE_APP_IMAGE' -n '$PROJECT_NAME'"
    log INFO "Sample app deployment requested."
  fi
fi

################################################################################
# Summary and next steps
################################################################################

log INFO "OpenShift client install and bootstrap completed (or simulated)."
log INFO "Summary:"
log INFO " - oc version desired: $OCP_VERSION"
log INFO " - Install dir: $INSTALL_DIR"
log INFO " - Symlink: $OC_SYMLINK"
log INFO " - Backup dir: $BACKUP_DIR"
log INFO " - Log file: $LOG_FILE"

if [[ "${SKIP_CLUSTER_OPS:-true}" == true ]]; then
  log INFO "Cluster operations were skipped. Ensure you have network access and credentials to the cluster and re-run with --apply when ready."
else
  log INFO "Cluster operations completed or requested. Validate project and deployments with: oc get all -n $PROJECT_NAME"
fi

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Dry-run was enabled. Re-run with --apply to make changes."
fi

log INFO "Script finished."
