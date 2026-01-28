#!/bin/bash
# Proxmox iSCSI Multipath Storage Plugin Uninstaller
# Run this script on each Proxmox VE node to remove the plugin

set -e

PLUGIN_DIR="/usr/share/perl5/PVE/Storage/Custom"
SCRIPT_INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONF_DIR="/etc/iscsi-mpath"
BACKUP_DIR="/var/lib/iscsi-mpath-plugin"
PVEMANAGERLIB="/usr/share/pve-manager/js/pvemanagerlib.js"
BACKUP_FILE="$BACKUP_DIR/pvemanagerlib.js.original"
MARKER_START="// ========== ISCSI-MPATH-PLUGIN-START =========="
MARKER_END="// ========== ISCSI-MPATH-PLUGIN-END =========="

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

log "Uninstalling Proxmox iSCSI Multipath Storage Plugin..."

# Stop and disable any active iscsi-mpath-connect services
log "Stopping iSCSI Multipath connection services..."
for service in /etc/systemd/system/multi-user.target.wants/iscsi-mpath-connect@*.service; do
    if [ -L "$service" ]; then
        instance=$(basename "$service" | sed 's/iscsi-mpath-connect@\(.*\)\.service/\1/')
        log "Stopping iscsi-mpath-connect@$instance..."
        systemctl stop "iscsi-mpath-connect@$instance" 2>/dev/null || true
        systemctl disable "iscsi-mpath-connect@$instance" 2>/dev/null || true
    fi
done

# Remove systemd service
log "Removing systemd service..."
if [ -f "$SYSTEMD_DIR/iscsi-mpath-connect@.service" ]; then
    rm -f "$SYSTEMD_DIR/iscsi-mpath-connect@.service"
    systemctl daemon-reload
fi

# Remove plugin
log "Removing ISCSIMultipathPlugin.pm..."
if [ -f "$PLUGIN_DIR/ISCSIMultipathPlugin.pm" ]; then
    rm -f "$PLUGIN_DIR/ISCSIMultipathPlugin.pm"
fi

# Remove helper scripts
log "Removing helper scripts..."
rm -f "$SCRIPT_INSTALL_DIR/iscsi-connect.sh"
rm -f "$SCRIPT_INSTALL_DIR/iscsi-cluster-sync.sh"
rm -f "$SCRIPT_INSTALL_DIR/iscsi-rescan.sh"

# Ask about configuration directory
if [ -d "$CONF_DIR" ]; then
    echo ""
    read -p "Remove configuration directory $CONF_DIR? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing configuration directory..."
        rm -rf "$CONF_DIR"
    else
        log "Keeping configuration directory $CONF_DIR"
    fi
fi

# Check for active iSCSI sessions
log "Checking for active iSCSI sessions..."
if command -v iscsiadm &> /dev/null; then
    active_sessions=$(iscsiadm -m session 2>/dev/null | wc -l || echo "0")
    if [ "$active_sessions" -gt 0 ]; then
        warn "There are still $active_sessions active iSCSI session(s)."
        warn "These were not disconnected. To disconnect manually, use:"
        warn "  iscsiadm -m node -T <target-iqn> -u"
        warn "  or: iscsiadm -m node --logoutall=all"
    fi
fi

# Check for storage definitions
if [ -f /etc/pve/storage.cfg ]; then
    iscsi_storage=$(grep -c "^iscsimpath:" /etc/pve/storage.cfg 2>/dev/null | head -1 | tr -d '\n' || echo "0")
    iscsi_storage=${iscsi_storage:-0}
    if [ "$iscsi_storage" -gt 0 ] 2>/dev/null; then
        warn ""
        warn "Found $iscsi_storage iSCSI Multipath storage definition(s) in /etc/pve/storage.cfg"
        warn "These were not removed. Please remove them manually if needed."
    fi
fi

# Restart pvedaemon to unload the plugin
log "Restarting pvedaemon..."
systemctl restart pvedaemon 2>/dev/null || warn "Failed to restart pvedaemon"

# Restore GUI (pvemanagerlib.js)
log "Checking for GUI modifications..."
if [ -f "$PVEMANAGERLIB" ] && grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
    if [ -f "$BACKUP_FILE" ]; then
        log "Restoring original pvemanagerlib.js from backup..."
        cp "$BACKUP_FILE" "$PVEMANAGERLIB"
        log "Restarting pveproxy..."
        systemctl restart pveproxy 2>/dev/null || warn "Failed to restart pveproxy"
    else
        log "Removing appended iSCSI Multipath GUI code..."
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$PVEMANAGERLIB"
        log "Restarting pveproxy..."
        systemctl restart pveproxy 2>/dev/null || warn "Failed to restart pveproxy"
    fi
else
    log "No GUI modifications found"
fi

# Clean up backup directory
if [ -d "$BACKUP_DIR" ]; then
    echo ""
    read -p "Remove backup directory $BACKUP_DIR? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing backup directory..."
        rm -rf "$BACKUP_DIR"
    else
        log "Keeping backup directory $BACKUP_DIR"
    fi
fi

log ""
log "============================================"
log "Uninstallation complete!"
log "============================================"
log ""
log "Note: The following were NOT removed:"
log "  - open-iscsi package and configuration"
log "  - multipath-tools package and /etc/multipath.conf"
log "  - /etc/iscsi/initiatorname.iscsi"
log "  - Any active iSCSI sessions"
log "  - Storage definitions in /etc/pve/storage.cfg"
log ""
log "To fully remove iSCSI/multipath support, also run:"
log "  apt-get remove open-iscsi multipath-tools"
log ""

