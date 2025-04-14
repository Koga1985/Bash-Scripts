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
if ! sudo apt-get update; then
    error_exit "Failed to update package list."
fi

#----------------------------------------------
# 2. Install Docker
#----------------------------------------------
log "Installing Docker..."
if ! sudo apt-get install -y docker.io; then
    error_exit "Failed to install Docker."
fi

#----------------------------------------------
# 3. Enable and Start Docker Service
#----------------------------------------------
log "Enabling and starting Docker service..."
if ! sudo systemctl enable docker; then
    error_exit "Failed to enable Docker service."
fi

if ! sudo systemctl start docker; then
    error_exit "Failed to start Docker service."
fi

#----------------------------------------------
# 4. Install Kubernetes Components
#----------------------------------------------
log "Installing prerequisites for Kubernetes components (apt-transport-https, curl)..."
if ! sudo apt-get install -y apt-transport-https curl; then
    error_exit "Failed to install prerequisites for Kubernetes."
fi

log "Adding Kubernetes GPG key..."
if ! curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -; then
    error_exit "Failed to add Kubernetes GPG key."
fi

log "Adding Kubernetes repository..."
echo "deb $KUBERNETES_REPO $KUBERNETES_RELEASE main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

log "Updating package list after adding Kubernetes repository..."
if ! sudo apt-get update; then
    error_exit "Failed to update package list after adding Kubernetes repository."
fi

log "Installing kubelet, kubeadm, and kubectl..."
if ! sudo apt-get install -y kubelet kubeadm kubectl; then
    error_exit "Failed to install Kubernetes components."
fi

#----------------------------------------------
# 5. Initialize Kubernetes Cluster
#----------------------------------------------
log "Initializing Kubernetes cluster with Pod network CIDR: $POD_NETWORK_CIDR..."
if ! sudo kubeadm init --pod-network-cidr="$POD_NETWORK_CIDR"; then
    error_exit "Failed to initialize Kubernetes cluster."
fi

#----------------------------------------------
# 6. Configure kubectl for the Current User
#----------------------------------------------
log "Configuring kubectl for the current user..."
if ! mkdir -p "$HOME/.kube"; then
    error_exit "Failed to create .kube directory."
fi

if ! sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"; then
    error_exit "Failed to copy admin.conf to .kube/config."
fi

if ! sudo chown $(id -u):$(id -g) "$HOME/.kube/config"; then
    error_exit "Failed to set ownership of .kube/config."
fi

#----------------------------------------------
# 7. Install Flannel Pod Network Add-On
#----------------------------------------------
log "Installing Flannel Pod network add-on using YAML from $FLANNEL_YAML..."
if ! kubectl apply -f "$FLANNEL_YAML"; then
    error_exit "Failed to apply Flannel YAML configuration."
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
