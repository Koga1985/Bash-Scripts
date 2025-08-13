#!/bin/bash
#===============================================================================
# Script Name: deploy_kasten_k10.sh
# Description:
#   This script installs and configures Kasten K10, a Kubernetes backup solution, 
#   by adding the Kasten Helm repository, updating repos, installing Kasten K10 
#   via Helm, and then waiting for the Kasten controller pod to be ready.
#   It also sets up port forwarding to expose the Kasten K10 dashboard locally.
#
# Prerequisites:
#   - Helm and kubectl must be installed and available in your PATH.
#   - You must have appropriate access to your Kubernetes cluster.
#   - Run the script with a user that has permissions to install Helm charts and manage pods.
#
# Usage:
#   sudo ./deploy_kasten_k10.sh
#
# Disclaimer:
#   This script is provided "as is" without warranty of any kind. Use it at your own risk.
#===============================================================================

# Exit immediately if a command exits with a non-zero status,
# if an undefined variable is used, or if any pipeline returns a non-zero status.

set -euo pipefail
IFS=$'\n\t'

# Trap unexpected errors
trap 'error_exit "Unexpected error occurred on line $LINENO."' ERR

#----------------------------------------------
# Variables
#----------------------------------------------
HELM_REPO_NAME="kasten"                           # Name of the Helm repository to add
HELM_REPO_URL="https://charts.kasten.io/"         # URL for the Kasten Helm charts
HELM_RELEASE_NAME="k10"                           # Name for the Helm release to install
NAMESPACE="kasten-io"                             # Kubernetes namespace for Kasten deployment
SERVICE_NAME="gateway"                            # Name of the Kubernetes Service for the Kasten dashboard
LOCAL_PORT=8080                                   # Local port for port-forwarding
REMOTE_PORT=8000                                  # Remote port exposed by the Service

#----------------------------------------------
# Logging Functions
#----------------------------------------------
# log: Outputs informational messages with a timestamp.
log() {
    echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# error_exit: Outputs an error message and exits the script.
error_exit() {
    echo -e "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    exit 1
}

#----------------------------------------------
# Pre-Flight: Check for helm and kubectl Commands
#----------------------------------------------
if ! command -v helm &>/dev/null; then
    error_exit "Helm is not installed. Please install Helm and try again."
fi

if ! command -v kubectl &>/dev/null; then
    error_exit "kubectl is not installed. Please install kubectl and try again."
fi

#----------------------------------------------
# 1. Add the Kasten Helm Repository
#----------------------------------------------
if helm repo list | grep -q "^${HELM_REPO_NAME}\b"; then
    log "Helm repo '${HELM_REPO_NAME}' already exists. Skipping add."
else
    log "Adding the Kasten Helm repository..."
    if ! helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL"; then
            error_exit "Failed to add Helm repository."
    fi
fi

#----------------------------------------------
# 2. Update Helm Repositories
#----------------------------------------------
log "Updating Helm repositories..."
if ! helm repo update; then
    error_exit "Failed to update Helm repositories."
fi

#----------------------------------------------
# 3. Install or Upgrade Kasten K10
#----------------------------------------------
if helm status "$HELM_RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Helm release '$HELM_RELEASE_NAME' already exists in namespace '$NAMESPACE'. Upgrading instead of installing."
    if ! helm upgrade "$HELM_RELEASE_NAME" "$HELM_REPO_NAME/$HELM_RELEASE_NAME" --namespace "$NAMESPACE"; then
        error_exit "Failed to upgrade Kasten K10."
    fi
else
    log "Installing Kasten K10..."
    if ! helm install "$HELM_RELEASE_NAME" "$HELM_REPO_NAME/$HELM_RELEASE_NAME" --namespace "$NAMESPACE" --create-namespace; then
        error_exit "Failed to install Kasten K10."
    fi
fi

#----------------------------------------------
# 4. Wait for Kasten K10 Controller Pod to be Ready
#----------------------------------------------
log "Waiting for Kasten K10 controller pod to be ready (timeout: 300 seconds)..."
if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=300s -n "$NAMESPACE"; then
    error_exit "Kasten K10 controller pod failed to become ready within the timeout period."
fi

#----------------------------------------------
# 5. Port-Forward the Kasten K10 Dashboard to Localhost
#----------------------------------------------
log "Port-forwarding Kasten K10 dashboard to localhost on port $LOCAL_PORT..."
if ! kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null; then
    error_exit "Service '$SERVICE_NAME' not found in namespace '$NAMESPACE'."
fi
if ! kubectl port-forward svc/"$SERVICE_NAME" -n "$NAMESPACE" "$LOCAL_PORT":"$REMOTE_PORT"; then
        error_exit "Failed to port-forward the Kasten K10 dashboard."
fi

#----------------------------------------------
# 6. Display Dashboard URL
#----------------------------------------------
log "Kasten K10 dashboard is now available at http://localhost:$LOCAL_PORT/k10/#/"

#----------------------------------------------
# 7. Summary
#----------------------------------------------
log "Kasten K10 deployment script completed successfully."
log "Helm repo: $HELM_REPO_NAME ($HELM_REPO_URL)"
log "Helm release: $HELM_RELEASE_NAME"
log "Namespace: $NAMESPACE"
log "Dashboard: http://localhost:$LOCAL_PORT/k10/#/"

# End of Script
