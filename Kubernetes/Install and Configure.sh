#!/usr/bin/env bash
#
# Kubernetes Bootstrap Script (Enterprise-ready)
# - Idempotent, documented, and safe by default (dry-run).
# - Use --apply to perform changes. Supports --verbose and --yes.
#
# Note: This is intended for single-node or small lab clusters. For production,
# use your infrastructure automation (Terraform/Ansible) and follow your provider's best
# practices for bootstrapping control planes, HA, storage, and networking.

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Configuration (tune these values for your environment)
################################################################################

# Operational flags
DRY_RUN=true
VERBOSE=false
FORCE=false

# Kubernetes settings
POD_NETWORK_CIDR="192.168.0.0/16"
FLANNEL_YAML="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
KUBERNETES_REPO="https://apt.kubernetes.io/"
KUBERNETES_RELEASE="kubernetes-xenial"
BACKUP_DIR="/var/tmp/k8s-backup-$(date +%Y%m%d%H%M%S)"
LOG_FILE="/var/log/k8s_install.log"

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

REQUIRED_TOOLS=(apt-get curl systemctl)
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
Usage: $0 [--apply] [--yes] [--verbose] [--pod-network-cidr CIDR] [--flannel-yaml URL]

Defaults to dry-run. Options:
  --apply                 Apply changes (disable dry-run)
  --yes, -y               Skip confirmations
  --verbose, -v           Enable verbose debug output
  --pod-network-cidr CIDR Override default pod network CIDR
  --flannel-yaml URL      Override default Flannel YAML URL
  --help, -h              Show this help message
USAGE
}

while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --yes|-y) FORCE=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --pod-network-cidr) POD_NETWORK_CIDR="$2"; shift 2 ;;
    --flannel-yaml) FLANNEL_YAML="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log WARN "Unknown option: $1"; usage; exit 2 ;;
  esac
done

log INFO "Kubernetes bootstrap starting"
log INFO "Dry-run: $DRY_RUN, Verbose: $VERBOSE, Force: $FORCE"

################################################################################
# Backup critical files
################################################################################

log INFO "Preparing backup directory: $BACKUP_DIR"
run_cmd "mkdir -p '$BACKUP_DIR' && chmod 700 '$BACKUP_DIR'"
backup_file_if_exists "/etc/apt/sources.list.d/kubernetes.list"
backup_file_if_exists "/etc/kubernetes/admin.conf"

################################################################################
# 1) Update package list
################################################################################

log INFO "Updating package cache"
run_cmd "apt-get update"

################################################################################
# 2) Install Docker (if missing)
################################################################################

if command -v docker &>/dev/null; then
  log INFO "Docker already installed. Skipping."
else
  log INFO "Installing Docker (docker.io)"
  run_cmd "apt-get install -y docker.io"
fi

################################################################################
# 3) Enable and start Docker service
################################################################################

log INFO "Ensuring Docker service is enabled and running"
run_cmd "systemctl enable docker || true"
run_cmd "systemctl start docker || true"

################################################################################
# 4) Install Kubernetes components (kubelet, kubeadm, kubectl)
################################################################################

log INFO "Installing prerequisites for Kubernetes (apt-transport-https, curl)"
run_cmd "apt-get install -y apt-transport-https ca-certificates curl"

if ! apt-key list | grep -q "Google Cloud Packages Automatic Signing Key"; then
  log INFO "Adding Kubernetes apt GPG key"
  run_cmd "curl -fsS https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -"
else
  log INFO "Kubernetes GPG key already present"
fi

if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]]; then
  log INFO "Adding Kubernetes apt repository"
  run_cmd "bash -c 'echo \"deb $KUBERNETES_REPO $KUBERNETES_RELEASE main\" > /etc/apt/sources.list.d/kubernetes.list'"
else
  log INFO "Kubernetes repository already configured"
fi

log INFO "Updating apt cache after adding Kubernetes repo"
run_cmd "apt-get update"

if command -v kubelet &>/dev/null && command -v kubeadm &>/dev/null && command -v kubectl &>/dev/null; then
  log INFO "Kubernetes components already installed. Skipping package installation."
else
  log INFO "Installing kubelet, kubeadm, kubectl"
  run_cmd "apt-get install -y kubelet kubeadm kubectl"
fi

################################################################################
# 5) Initialize Kubernetes cluster
################################################################################

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log INFO "Initializing Kubernetes control plane with pod network CIDR: $POD_NETWORK_CIDR"
  if [[ "$DRY_RUN" == true ]]; then
    log INFO "DRY-RUN: kubeadm init --pod-network-cidr=$POD_NETWORK_CIDR"
  else
    run_cmd "kubeadm init --pod-network-cidr='$POD_NETWORK_CIDR'"
  fi
else
  log INFO "Kubernetes appears already initialized (admin.conf present). Skipping init."
fi

################################################################################
# 6) Configure kubectl for current user
################################################################################

if [[ ! -f "$HOME/.kube/config" ]]; then
  log INFO "Configuring kubectl for the current user"
  run_cmd "mkdir -p '$HOME/.kube'"
  run_cmd "cp -i /etc/kubernetes/admin.conf '$HOME/.kube/config'"
  run_cmd "chown $(id -u):$(id -g) '$HOME/.kube/config'"
else
  log INFO "kubectl already configured for the current user"
fi

################################################################################
# 7) Install Flannel network add-on
################################################################################

log INFO "Ensuring Flannel pod network add-on is applied: $FLANNEL_YAML"
if kubectl get pods -n kube-system 2>/dev/null | grep -q flannel; then
  log INFO "Flannel already appears installed. Skipping."
else
  run_cmd "kubectl apply -f '$FLANNEL_YAML'"
fi

################################################################################
# 8) Wait for nodes to become Ready
################################################################################

log INFO "Waiting for nodes to become Ready (timeout: 300s)"
run_cmd "kubectl get nodes || true"
if [[ "$DRY_RUN" == true ]]; then
  log INFO "DRY-RUN: kubectl wait --for=condition=Ready nodes --all --timeout=300s"
else
  run_cmd "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
fi

################################################################################
# Final summary / next steps
################################################################################

log INFO "Kubernetes bootstrap completed (or simulated)."
log INFO "Summary:"
log INFO " - Pod network CIDR: $POD_NETWORK_CIDR"
log INFO " - Flannel YAML: $FLANNEL_YAML"
log INFO " - Backup dir: $BACKUP_DIR"
log INFO " - Log file: $LOG_FILE"

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Dry-run was enabled. Re-run with --apply to perform the changes."
fi

log INFO "Next steps:"
log INFO " - Verify nodes: kubectl get nodes"
log INFO " - Check pods: kubectl get pods -A"
log INFO " - Configure storage, ingress, and other cluster services as needed."
