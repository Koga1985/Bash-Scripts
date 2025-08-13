#!/bin/bash
#===============================================================================
# Script Name: install_openshift.sh
#
# Description:
#   This script installs and configures the OpenShift client (oc) on a Linux system.
#   It downloads a specified version of the OpenShift client, extracts it to a chosen 
#   installation directory, adds the directory to your PATH, logs into an OpenShift cluster 
#   as the cluster admin, creates a new project, and deploys a sample application.
#
# Prerequisites:
#   - This script must be run on a system with a supported Linux distribution (Ubuntu/Debian).
#   - The OpenShift CLI (oc) must not be pre-installed, or you wish to update it.
#   - Internet connectivity is required for downloading the OpenShift client.
#   - Sudo privileges are needed for directory creation, file extraction, etc.
#
# Usage:
#   sudo ./install_openshift.sh
#
# Disclaimer:
#   This script is provided "as is" without warranty of any kind. Use at your own risk.
#
# Author: Your Name or Organization
# Date:   2025-04-14
# Version: 1.1
#===============================================================================

# Exit immediately if a command exits with a non-zero status,
# an undefined variable is used, or any command in a pipeline fails.

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
# Variables
#----------------------------------------------
OCP_VERSION="4.9.0"                                 # Desired OpenShift version
INSTALL_DIR="/opt/openshift"                        # Directory to install the OpenShift client
PROJECT_NAME="myproject"                            # Name of the new OpenShift project to create
SAMPLE_APP="openshift/deployment-example"           # Sample application image to deploy
LOG_FILE="/var/log/openshift_install.log"           # Log file for script output

#----------------------------------------------
# Functions
#----------------------------------------------
# log: Outputs informational messages along with a timestamp.
function log() {
  local message="$1"
  echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $message"
  echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# error_exit: Outputs an error message, writes it to stderr and the log file, then exits.
function error_exit() {
  local message="$1"
  echo -e "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $message" >&2
  echo -e "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
  exit 1
}

#----------------------------------------------
# 1. Pre-flight Check: Ensure 'oc' CLI is not already installed (or update as necessary)
#----------------------------------------------

log "Checking for OpenShift CLI (oc)..."
if command -v oc &>/dev/null; then
  INSTALLED_VERSION=$(oc version --client | grep -oP 'Client Version: \K[0-9.]+')
  if [[ "$INSTALLED_VERSION" == "$OCP_VERSION" ]]; then
    log "OpenShift CLI version $OCP_VERSION is already installed. Skipping download."
  else
    log "OpenShift CLI is installed (version $INSTALLED_VERSION), updating to $OCP_VERSION."
  fi
else
  log "OpenShift CLI not found. Proceeding with installation."
fi

#----------------------------------------------
# 2. Create Installation Directory
#----------------------------------------------

log "Creating installation directory at '$INSTALL_DIR'..."
if [[ ! -d "$INSTALL_DIR" ]]; then
  if ! mkdir -p "$INSTALL_DIR"; then
    error_exit "Failed to create directory '$INSTALL_DIR'."
  fi
  if ! chown "$(whoami):$(whoami)" "$INSTALL_DIR"; then
    error_exit "Failed to set ownership of '$INSTALL_DIR'."
  fi
else
  log "Installation directory '$INSTALL_DIR' already exists."
fi

#----------------------------------------------
# 3. Download and Extract OpenShift Client
#----------------------------------------------

ISO_FILE="/tmp/openshift-client-linux-$OCP_VERSION.tar.gz"
if ! command -v oc &>/dev/null || [[ "$INSTALLED_VERSION" != "$OCP_VERSION" ]]; then
  log "Downloading OpenShift client version $OCP_VERSION..."
  if ! wget -q "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-client-linux-$OCP_VERSION.tar.gz" -O "$ISO_FILE"; then
    error_exit "Failed to download OpenShift client."
  fi
  log "Extracting OpenShift client to '$INSTALL_DIR'..."
  if ! tar -zxvf "$ISO_FILE" -C "$INSTALL_DIR"; then
    error_exit "Failed to extract OpenShift client."
  fi
  export PATH="$PATH:$INSTALL_DIR"
  log "OpenShift CLI installed/updated successfully."
else
  log "OpenShift CLI version $OCP_VERSION already present."
fi

#----------------------------------------------
# 4. Login as Cluster Admin
#----------------------------------------------

log "Logging in as cluster admin..."
if ! oc whoami &>/dev/null; then
  if ! oc login -u system:admin &>/dev/null; then
    error_exit "Failed to log in as system:admin. Ensure your OpenShift cluster is up and accessible."
  fi
  log "Logged in successfully."
else
  log "Already logged in as $(oc whoami)."
fi

#----------------------------------------------
# 5. Create a New Project
#----------------------------------------------

log "Creating new OpenShift project: '$PROJECT_NAME'..."
if oc get project "$PROJECT_NAME" &>/dev/null; then
  log "Project '$PROJECT_NAME' already exists. Skipping creation."
else
  if ! oc new-project "$PROJECT_NAME" &>/dev/null; then
    error_exit "Failed to create project '$PROJECT_NAME'. Ensure you have the required permissions."
  fi
  log "Project '$PROJECT_NAME' created successfully."
fi

#----------------------------------------------
# 6. Deploy a Sample Application
#----------------------------------------------

log "Deploying sample application '$SAMPLE_APP'..."
if oc get all -n "$PROJECT_NAME" | grep -q "$SAMPLE_APP"; then
  log "Sample application '$SAMPLE_APP' already deployed in project '$PROJECT_NAME'."
else
  if ! oc new-app "$SAMPLE_APP" &>/dev/null; then
    error_exit "Failed to deploy sample application '$SAMPLE_APP'. Ensure the image exists and is accessible."
  fi
  log "Sample application deployed successfully."
fi

#----------------------------------------------
# 7. Final Notification
#----------------------------------------------

log "OpenShift installation and configuration completed successfully."
log "Summary:"
log "- OpenShift CLI version $OCP_VERSION installed in $INSTALL_DIR."
log "- Logged in as $(oc whoami)."
log "- Project '$PROJECT_NAME' is ready."
log "- Sample application '$SAMPLE_APP' deployed."
log "Next steps:"
log "- Use 'oc get all -n $PROJECT_NAME' to view resources."
log "- Access your OpenShift cluster and application as needed."
