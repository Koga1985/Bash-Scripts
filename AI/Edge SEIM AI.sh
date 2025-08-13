
#!/bin/bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
  log "ERROR: This script must be run as root. Use sudo or run as root."
  exit 1
fi

log "Starting deployment of Edge AI for SIEM..."

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Use sudo or run as root."
  exit 1
fi

echo "Starting deployment of Edge AI for SIEM..."

##############################
# Variables
##############################
LOG_FORWARDING_HOST="192.168.1.100"       # Centralized SIEM IP
LOG_FORWARDING_PORT="514"                 # Syslog port (default UDP port is 514)
RETENTION_DAYS=30                         # Days to retain logs
EDGE_AI_SCRIPT="/opt/edge_ai_detection.py"  # Destination for the AI script
EDGE_AI_SERVICE="edge_ai"                 # systemd service name
RSYSLOG_CONF="/etc/rsyslog.d/edge_ai_forwarding.conf"  # rsyslog configuration file
LOGROTATE_CONF="/etc/logrotate.d/edge-ai" # logrotate configuration file

##############################
# Pre-Tasks: Ensure /opt directory exists
##############################

if [[ ! -d /opt ]]; then
  mkdir -p /opt && chmod 0755 /opt
  log "Ensured /opt directory exists with permissions 0755."
else
  log "/opt directory already exists."
fi

##############################
# Install required system packages
##############################

log "Updating package cache and installing packages..."
if ! apt-get update; then
  log "ERROR: apt-get update failed."
  exit 2
fi
if ! apt-get install -y \
  python3 \
  python3-pip \
  rsyslog \
  logrotate \
  prometheus-node-exporter \
  nvidia-container-toolkit; then
  log "ERROR: Package installation failed."
  exit 3
fi

##############################
# Install Python libraries for machine learning
##############################

log "Installing Python libraries..."
if ! pip3 install numpy scikit-learn pandas; then
  log "ERROR: Python package installation failed."
  exit 4
fi

##############################
# Deploy Edge AI detection script
##############################

# Assumes the local script file "edge_ai_detection.py" exists in the current directory
if [[ ! -f "./edge_ai_detection.py" ]]; then
  log "ERROR: edge_ai_detection.py not found in the current directory."
  exit 5
fi

if ! cp ./edge_ai_detection.py "$EDGE_AI_SCRIPT"; then
  log "ERROR: Failed to copy edge_ai_detection.py to $EDGE_AI_SCRIPT."
  exit 6
fi
chmod 0755 "$EDGE_AI_SCRIPT"
chown root:root "$EDGE_AI_SCRIPT"
log "Deployed Edge AI detection script to $EDGE_AI_SCRIPT."

##############################
# Configure rsyslog to forward logs to centralized SIEM
##############################

log "Configuring rsyslog to forward logs to SIEM..."
echo "*.* @@${LOG_FORWARDING_HOST}:${LOG_FORWARDING_PORT}" | tee "$RSYSLOG_CONF" > /dev/null
chmod 0644 "$RSYSLOG_CONF"
chown root:root "$RSYSLOG_CONF"
if ! systemctl restart rsyslog; then
  log "ERROR: Failed to restart rsyslog."
  exit 7
fi
log "Configured rsyslog to forward logs and restarted rsyslog."

##############################
# Configure logrotate for Edge AI logs
##############################

log "Configuring logrotate for Edge AI logs..."
cat <<EOF | tee "$LOGROTATE_CONF" > /dev/null
/var/log/edge-ai/*.log {
  daily
  rotate ${RETENTION_DAYS}
  compress
  missingok
  notifempty
}
EOF
chmod 0644 "$LOGROTATE_CONF"
chown root:root "$LOGROTATE_CONF"
log "Configured logrotate for Edge AI logs."

##############################
# Enable and start Prometheus Node Exporter
##############################

log "Enabling and starting Prometheus Node Exporter..."
if ! systemctl is-enabled prometheus-node-exporter &>/dev/null; then
  systemctl enable prometheus-node-exporter
fi
if ! systemctl is-active prometheus-node-exporter &>/dev/null; then
  systemctl start prometheus-node-exporter
fi
log "Prometheus Node Exporter is enabled and running."

##############################
# Create systemd service for Edge AI script
##############################

log "Creating systemd service for Edge AI script..."
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${EDGE_AI_SERVICE}.service"
cat <<EOF | tee "$SYSTEMD_SERVICE_FILE" > /dev/null
[Unit]
Description=Edge AI Log Analyzer
After=network.target

[Service]
ExecStart=/usr/bin/python3 ${EDGE_AI_SCRIPT}
Restart=always
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SYSTEMD_SERVICE_FILE"
chown root:root "$SYSTEMD_SERVICE_FILE"
systemctl daemon-reload
log "Created systemd service for Edge AI and reloaded systemd."

##############################
# Enable and start Edge AI systemd service
##############################

log "Enabling and starting Edge AI systemd service..."
if ! systemctl is-enabled "${EDGE_AI_SERVICE}.service" &>/dev/null; then
  systemctl enable "${EDGE_AI_SERVICE}.service"
fi
if ! systemctl is-active "${EDGE_AI_SERVICE}.service" &>/dev/null; then
  systemctl start "${EDGE_AI_SERVICE}.service"
fi
log "Edge AI service is enabled and running."


log "Deployment complete."
