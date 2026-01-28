#!/bin/bash
# Install iSCSI Multipath dependencies on Proxmox VE nodes
# Run this on each node in the cluster

set -e

SCRIPT_NAME=$(basename "$0")
LOG_TAG="iscsi-mpath-install"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

# Check if running on Proxmox VE
if [ ! -f /etc/pve/local/pve-ssl.pem ]; then
    log "Warning: This doesn't appear to be a Proxmox VE node"
fi

log "Installing iSCSI Multipath dependencies..."

# Update package list
apt-get update

# Install open-iscsi
log "Installing open-iscsi..."
apt-get install -y open-iscsi

# Install multipath-tools
log "Installing multipath-tools..."
apt-get install -y multipath-tools

# Enable and start iscsid
log "Enabling iscsid service..."
systemctl enable iscsid
systemctl start iscsid

# Enable and start multipathd
log "Enabling multipathd service..."
systemctl enable multipathd
systemctl start multipathd

# Create multipath.conf if it doesn't exist
if [ ! -f /etc/multipath.conf ]; then
    log "Creating basic multipath.conf..."
    cat > /etc/multipath.conf << 'EOF'
# Multipath configuration for iSCSI
# See: man multipath.conf

defaults {
    user_friendly_names yes
    find_multipaths yes
    path_grouping_policy failover
    failback immediate
    no_path_retry queue
}

blacklist {
    # Exclude local disks
    devnode "^sd[a-z]$"
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^nvme[0-9]"
}

blacklist_exceptions {
    # Include iSCSI devices (they show as sd* too, but we want them)
    property "(SCST_BIO|LIO-ORG)"
    protocol "iscsi"
}
EOF
else
    log "multipath.conf already exists, skipping creation"
fi

# Restart multipathd to apply configuration
log "Restarting multipathd..."
systemctl restart multipathd

# Generate initiator name if not exists
if [ ! -f /etc/iscsi/initiatorname.iscsi ] || ! grep -q "^InitiatorName=" /etc/iscsi/initiatorname.iscsi; then
    log "Generating initiator name..."
    INITIATOR_NAME="iqn.$(date +%Y-%m).$(hostname -d | awk -F. '{for(i=NF;i>0;i--) printf $i"."}' | sed 's/\.$//')$(hostname -s)"
    echo "InitiatorName=$INITIATOR_NAME" > /etc/iscsi/initiatorname.iscsi
fi

INITIATOR=$(grep "^InitiatorName=" /etc/iscsi/initiatorname.iscsi | cut -d= -f2)
log "Initiator Name: $INITIATOR"

# Restart iscsid to apply changes
log "Restarting iscsid..."
systemctl restart iscsid

log "iSCSI Multipath dependencies installed successfully!"
log ""
log "Next steps:"
log "1. Copy ISCSIMultipathPlugin.pm to /usr/share/perl5/PVE/Storage/Custom/"
log "2. Configure storage in /etc/pve/storage.cfg or via pvesm"
log "3. Restart pvedaemon: systemctl restart pvedaemon"
log ""
log "Example storage.cfg entry:"
log "  iscsimpath: iscsi-storage"
log "      iscsi_portal 192.168.1.100,192.168.1.101"
log "      iscsi_target iqn.2024-01.com.example:storage"
log "      content images"
log "      shared 1"

