#!/bin/bash
set -e

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
mkdir -p /opt
chmod 0755 /opt
echo "Ensured /opt directory exists with permissions 0755."

##############################
# Install required system packages
##############################
echo "Updating package cache and installing packages..."
apt-get update
apt-get install -y \
  python3 \
  python3-pip \
  rsyslog \
  logrotate \
  prometheus-node-exporter \
  nvidia-container-toolkit

##############################
# Install Python libraries for machine learning
##############################
echo "Installing Python libraries..."
pip3 install numpy scikit-learn pandas

##############################
# Deploy Edge AI detection script
##############################
# Assumes the local script file "edge_ai_detection.py" exists in the current directory
if [[ ! -f "./edge_ai_detection.py" ]]; then
  echo "Error: edge_ai_detection.py not found in the current directory."
  exit 1
fi

cp ./edge_ai_detection.py "$EDGE_AI_SCRIPT"
chmod 0755 "$EDGE_AI_SCRIPT"
chown root:root "$EDGE_AI_SCRIPT"
echo "Deployed Edge AI detection script to $EDGE_AI_SCRIPT."

##############################
# Configure rsyslog to forward logs to centralized SIEM
##############################
cat <<EOF > "$RSYSLOG_CONF"
*.* @@${LOG_FORWARDING_HOST}:${LOG_FORWARDING_PORT}
EOF
chmod 0644 "$RSYSLOG_CONF"
chown root:root "$RSYSLOG_CONF"
systemctl restart rsyslog
echo "Configured rsyslog to forward logs and restarted rsyslog."

##############################
# Configure logrotate for Edge AI logs
##############################
cat <<EOF > "$LOGROTATE_CONF"
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
echo "Configured logrotate for Edge AI logs."

##############################
# Enable and start Prometheus Node Exporter
##############################
systemctl enable prometheus-node-exporter
systemctl start prometheus-node-exporter
echo "Enabled and started Prometheus Node Exporter."

##############################
# Create systemd service for Edge AI script
##############################
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${EDGE_AI_SERVICE}.service"
cat <<EOF > "$SYSTEMD_SERVICE_FILE"
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
echo "Created systemd service for Edge AI and reloaded systemd."

##############################
# Enable and start Edge AI systemd service
##############################
systemctl enable "${EDGE_AI_SERVICE}.service"
systemctl start "${EDGE_AI_SERVICE}.service"
echo "Enabled and started the Edge AI service."

echo "Deployment complete."
