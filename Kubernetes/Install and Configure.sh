#!/bin/bash
#===============================================================================
# Script Name: install_kubernetes.sh
# Description:
#   This script installs and configures a Kubernetes cluster on an Ubuntu system.
#   It performs the following actions:
#     1. Updates the package list.
#     2. Installs Docker.
#     3. Enables and starts the Docker service.
#     4. Installs Kubernetes components (kubelet, kubeadm, kubectl) using the 
#        official Kubernetes repository.
#     5. Initializes a Kubernetes cluster with a specified Pod network CIDR.
#     6. Configures kubectl for the current user.
#     7. Installs the Flannel Pod network add-on.
#     8. Waits for all nodes to reach the Ready state.
#
# Prerequisites:
#   - Must be run as root or with sudo privileges.
#   - The system must be running Ubuntu (or compatible distribution).
#   - Internet connectivity is required to download packages and resources.
#
# Disclaimer:
#   This script is provided "as is" without warranty of any kind. Use at your own risk.
#   Test in a development environment before running in production.
#
# Author: Your Name or Organization
# Date: 2025-04-14
# Version: 1.0
#===============================================================================

# Exit immediately if a command exits with a non-zero status, if any variable is unset,
# or if any command in a pipeline fails.

set -euo pipefail
IFS=$'\n\t'

# Trap unexpected errors
trap 'error_exit "Unexpected error occurred on line $LINENO."' ERR

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo or run as root." >&2
    exit 1
fi

#----------------------------------------------
# Global Variables
#----------------------------------------------
POD_NETWORK_CIDR="192.168.0.0/16"                # Pod network CIDR (adjust as necessary)
FLANNEL_YAML="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
KUBERNETES_REPO="http://apt.kubernetes.io/"
KUBERNETES_RELEASE="kubernetes-xenial"
LOG_FILE="/var/log/k8s_install.log"

#----------------------------------------------
# Logging Functions
#----------------------------------------------
# log: Outputs info messages with timestamp.
function log() {
  local message="$1"
  echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $message"
  echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# error_exit: Outputs an error message and terminates the script.
function error_exit() {
  local message="$1"
  echo -e "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $message" >&2
  echo -e "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
  exit 1
}

#----------------------------------------------
# 1. Update Package List
#----------------------------------------------

log "Updating package list..."
if ! apt-get update; then
    error_exit "Failed to update package list."
fi

#----------------------------------------------
# 2. Install Docker
#----------------------------------------------

if command -v docker &>/dev/null; then
    log "Docker is already installed. Skipping installation."
else
    log "Installing Docker..."
    if ! apt-get install -y docker.io; then
            error_exit "Failed to install Docker."
    fi
fi

#----------------------------------------------
# 3. Enable and Start Docker Service
#----------------------------------------------

log "Enabling and starting Docker service..."
if ! systemctl is-enabled docker &>/dev/null; then
    if ! systemctl enable docker; then
            error_exit "Failed to enable Docker service."
    fi
fi
if ! systemctl is-active docker &>/dev/null; then
    if ! systemctl start docker; then
            error_exit "Failed to start Docker service."
    fi
fi

#----------------------------------------------
# 4. Install Kubernetes Components
#----------------------------------------------

log "Installing prerequisites for Kubernetes components (apt-transport-https, curl)..."
if ! apt-get install -y apt-transport-https curl; then
        error_exit "Failed to install prerequisites for Kubernetes."
fi

if ! apt-key list | grep -q "Google Cloud Packages Automatic Signing Key"; then
    log "Adding Kubernetes GPG key..."
    if ! curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -; then
            error_exit "Failed to add Kubernetes GPG key."
    fi
else
    log "Kubernetes GPG key already present."
fi

if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]]; then
    log "Adding Kubernetes repository..."
    echo "deb $KUBERNETES_REPO $KUBERNETES_RELEASE main" | tee /etc/apt/sources.list.d/kubernetes.list
else
    log "Kubernetes repository already present."
fi

log "Updating package list after adding Kubernetes repository..."
if ! apt-get update; then
        error_exit "Failed to update package list after adding Kubernetes repository."
fi

if command -v kubelet &>/dev/null && command -v kubeadm &>/dev/null && command -v kubectl &>/dev/null; then
    log "Kubernetes components already installed. Skipping installation."
else
    log "Installing kubelet, kubeadm, and kubectl..."
    if ! apt-get install -y kubelet kubeadm kubectl; then
            error_exit "Failed to install Kubernetes components."
    fi
fi

#----------------------------------------------
# 5. Initialize Kubernetes Cluster
#----------------------------------------------

log "Initializing Kubernetes cluster with Pod network CIDR: $POD_NETWORK_CIDR..."
if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    if ! kubeadm init --pod-network-cidr="$POD_NETWORK_CIDR"; then
            error_exit "Failed to initialize Kubernetes cluster."
    fi
else
    log "Kubernetes cluster already initialized. Skipping init."
fi

#----------------------------------------------
# 6. Configure kubectl for the Current User
#----------------------------------------------

log "Configuring kubectl for the current user..."
if [[ ! -f "$HOME/.kube/config" ]]; then
    if ! mkdir -p "$HOME/.kube"; then
            error_exit "Failed to create .kube directory."
    fi
    if ! cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"; then
            error_exit "Failed to copy admin.conf to .kube/config."
    fi
    if ! chown $(id -u):$(id -g) "$HOME/.kube/config"; then
            error_exit "Failed to set ownership of .kube/config."
    fi
else
    log "kubectl already configured for current user."
fi

#----------------------------------------------
# 7. Install Flannel Pod Network Add-On
#----------------------------------------------

log "Installing Flannel Pod network add-on using YAML from $FLANNEL_YAML..."
if ! kubectl get pods -n kube-system | grep -q flannel; then
    if ! kubectl apply -f "$FLANNEL_YAML"; then
            error_exit "Failed to apply Flannel YAML configuration."
    fi
else
    log "Flannel Pod network already installed."
fi

#----------------------------------------------
# 8. Wait for All Nodes to Become Ready
#----------------------------------------------

log "Waiting for all Kubernetes nodes to be Ready (timeout: 300 seconds)..."
kubectl get nodes
if ! kubectl wait --for=condition=Ready nodes --all --timeout=300s; then
    error_exit "Nodes did not reach Ready state within the timeout period."
fi

#----------------------------------------------
# 9. Final Notification
#----------------------------------------------

log "Kubernetes installation and configuration complete. Your cluster is now ready."
log "Summary:"
log "Docker installed and running."
log "Kubernetes components installed."
log "Cluster initialized with Pod network CIDR: $POD_NETWORK_CIDR."
log "Flannel Pod network installed."
log "All nodes are Ready."
log "Next steps:"
log "- Use 'kubectl get nodes' to verify cluster status."
log "- Deploy workloads to your cluster."
