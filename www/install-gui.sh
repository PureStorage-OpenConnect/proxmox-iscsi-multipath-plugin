#!/bin/bash
# Install iSCSI Multipath Storage Plugin GUI for Proxmox VE
# Run this script on each Proxmox VE node after installing the backend plugin

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PVEMANAGERLIB="/usr/share/pve-manager/js/pvemanagerlib.js"
BACKUP_DIR="/var/lib/iscsi-mpath-plugin"
BACKUP_FILE="$BACKUP_DIR/pvemanagerlib.js.original"
MARKER_START="// ========== ISCSI-MPATH-PLUGIN-START =========="
MARKER_END="// ========== ISCSI-MPATH-PLUGIN-END =========="

# Tested pve-manager version - update this when testing on new versions
TESTED_PVE_VERSION="9.1.4"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

# Check if pvemanagerlib.js exists
if [ ! -f "$PVEMANAGERLIB" ]; then
    error "Proxmox pvemanagerlib.js not found at $PVEMANAGERLIB"
fi

# Check pve-manager version
log "Checking pve-manager version..."
CURRENT_VERSION=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

if [ "$CURRENT_VERSION" = "unknown" ]; then
    warn "Could not determine pve-manager version"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
elif [ "$CURRENT_VERSION" != "$TESTED_PVE_VERSION" ]; then
    warn "pve-manager version mismatch!"
    warn "  Installed: $CURRENT_VERSION"
    warn "  Tested:    $TESTED_PVE_VERSION"
    warn ""
    warn "This GUI patch was tested on pve-manager $TESTED_PVE_VERSION."
    warn "It may not work correctly on version $CURRENT_VERSION."
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    log "  [OK] pve-manager version $CURRENT_VERSION matches tested version"
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Check if already installed (look for our marker)
if grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
    log "iSCSI Multipath GUI is already installed."
    log "To reinstall, first run the uninstall script or restore the backup."
    exit 0
fi

# Backup original pvemanagerlib.js (only if we don't have a backup yet)
if [ ! -f "$BACKUP_FILE" ]; then
    log "Backing up original pvemanagerlib.js..."
    cp "$PVEMANAGERLIB" "$BACKUP_FILE"
else
    log "Backup already exists at $BACKUP_FILE"
fi

log "Installing iSCSI Multipath GUI..."

# Append our ExtJS class definitions with markers
log "  - Appending iSCSI Multipath GUI classes to pvemanagerlib.js..."
{
    echo ""
    echo "$MARKER_START"
    cat "$SCRIPT_DIR/ISCSIMultipathEdit.js"
    echo ""
    echo "$MARKER_END"
} >> "$PVEMANAGERLIB"

# Verify
if grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
    log "  [OK] iSCSI Multipath GUI code appended successfully"
else
    error "Failed to append GUI code"
fi

# Restart pveproxy to apply changes
log "Restarting pveproxy..."
systemctl restart pveproxy

log ""
log "============================================"
log "iSCSI Multipath GUI installation complete!"
log "============================================"
log ""
log "IMPORTANT: Clear your browser cache (Ctrl+Shift+R)"
log ""
log "iSCSI Multipath should now appear in: Datacenter -> Storage -> Add"
log ""
log "To uninstall: ./uninstall.sh"
log "Backup: $BACKUP_FILE"
log ""

