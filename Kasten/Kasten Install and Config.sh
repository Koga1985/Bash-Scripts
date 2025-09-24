#!/usr/bin/env bash
#
# Kasten K10 Helm Installer (Enterprise-ready)
# - Idempotent, documented, and safe by default (dry-run).
# - Use --apply to perform changes. Supports --verbose and --yes to skip prompts.
#
# Prerequisites:
# - kubectl and helm must be available in PATH and have access to the target cluster.
# - The operator running this script must have permissions to create namespaces and install charts.

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Defaults and configuration
################################################################################

DRY_RUN=true
VERBOSE=false
FORCE=false

HELM_REPO_NAME="kasten"
HELM_REPO_URL="https://charts.kasten.io/"
HELM_RELEASE_NAME="k10"
NAMESPACE="kasten-io"
SERVICE_NAME="gateway"
LOCAL_PORT=8080
REMOTE_PORT=8000
LOG_FILE="/var/log/kasten_install.log"
BACKUP_DIR="/var/tmp/kasten-backup-$(date +%Y%m%d%H%M%S)"

################################################################################
# Helpers
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

error_exit() { log ERROR "$*"; exit 1; }

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
    [[ "$response" == "yes" ]]
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

if ! command -v helm &>/dev/null; then
    error_exit "helm not found. Install helm and retry."
fi
if ! command -v kubectl &>/dev/null; then
    error_exit "kubectl not found. Install kubectl and ensure cluster access."
fi

################################################################################
# CLI args
################################################################################

usage() {
    cat <<-USAGE
Usage: $0 [--apply] [--yes] [--verbose] [--local-port PORT] [--help]

Defaults to dry-run. Options:
    --apply         Apply changes (disable dry-run)
    --yes, -y       Skip confirmations
    --verbose, -v   Enable verbose output
    --local-port    Local port to use for port-forward (default: $LOCAL_PORT)
    --help, -h      Show this help message
USAGE
}

while [[ ${#} -gt 0 ]]; do
    case "$1" in
        --apply) DRY_RUN=false; shift ;;
        --yes|-y) FORCE=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --local-port) LOCAL_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log WARN "Unknown option: $1"; usage; exit 2 ;;
    esac
done

log INFO "Kasten K10 installer starting (Dry-run: $DRY_RUN)"

################################################################################
# Backup cluster-level resources (no-op if not present)
################################################################################

run_cmd "mkdir -p '$BACKUP_DIR' && chmod 700 '$BACKUP_DIR'"
backup_file_if_exists "/etc/kubernetes/admin.conf" || true

################################################################################
# Add Helm repo and update
################################################################################

if helm repo list | awk '{print $1}' | grep -qx "$HELM_REPO_NAME"; then
    log INFO "Helm repo '$HELM_REPO_NAME' already present"
else
    log INFO "Adding Helm repo: $HELM_REPO_NAME -> $HELM_REPO_URL"
    run_cmd "helm repo add '$HELM_REPO_NAME' '$HELM_REPO_URL'"
fi

log INFO "Updating Helm repositories"
run_cmd "helm repo update"

################################################################################
# Install or upgrade Kasten K10 (idempotent)
################################################################################

if helm status "$HELM_RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    log INFO "Helm release $HELM_RELEASE_NAME exists in namespace $NAMESPACE. Will upgrade."
    run_cmd "helm upgrade '$HELM_RELEASE_NAME' '$HELM_REPO_NAME/$HELM_RELEASE_NAME' --namespace '$NAMESPACE'"
else
    log INFO "Installing Helm release $HELM_RELEASE_NAME into namespace $NAMESPACE"
    run_cmd "helm install '$HELM_RELEASE_NAME' '$HELM_REPO_NAME/$HELM_RELEASE_NAME' --namespace '$NAMESPACE' --create-namespace"
fi

################################################################################
# Wait for controller pod readiness
################################################################################

log INFO "Waiting for Kasten controller pod to become ready (timeout 300s)"
if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=300s -n "$NAMESPACE"; then
    error_exit "Kasten controller pod did not become ready in time. Check pod logs."
fi

################################################################################
# Port-forward dashboard (operator runs this in foreground intentionally)
################################################################################

if ! kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null; then
    error_exit "Service '$SERVICE_NAME' not found in namespace '$NAMESPACE'"
fi

log INFO "Port-forwarding service/$SERVICE_NAME:$REMOTE_PORT -> localhost:$LOCAL_PORT"
log INFO "Note: port-forward runs in foreground. Press CTRL-C to stop."
if [[ "$DRY_RUN" == true ]]; then
    log INFO "DRY-RUN: kubectl port-forward svc/$SERVICE_NAME -n $NAMESPACE $LOCAL_PORT:$REMOTE_PORT"
else
    exec kubectl port-forward svc/"$SERVICE_NAME" -n "$NAMESPACE" "$LOCAL_PORT":"$REMOTE_PORT"
fi

################################################################################
# Summary (will not be reached if port-forward execs)
################################################################################

log INFO "Kasten installer finished (or simulated)."
log INFO "Helm repo: $HELM_REPO_NAME ($HELM_REPO_URL)"
log INFO "Release: $HELM_RELEASE_NAME in namespace $NAMESPACE"
log INFO "Dashboard: http://localhost:$LOCAL_PORT/k10/#/"

# End
