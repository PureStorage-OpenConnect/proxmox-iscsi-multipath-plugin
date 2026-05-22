#!/bin/bash
# Proxmox iSCSI Multipath Storage Plugin Installer
# Run this script on each Proxmox VE node

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="/usr/share/perl5/PVE/Storage/Custom"
SCRIPT_INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONF_DIR="/etc/iscsi-mpath"

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

# Detect PVE version and Storage API version for APIVER compatibility
detect_pve_info() {
    PVE_FULL="unknown"
    PVE_MAJOR=0
    STORAGE_APIVER=13  # default to latest supported

    if command -v pveversion &>/dev/null; then
        PVE_FULL=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        PVE_MAJOR=$(echo "$PVE_FULL" | cut -d'.' -f1)
    fi

    local storage_pm="/usr/share/perl5/PVE/Storage.pm"
    if [ -f "$storage_pm" ]; then
        local detected
        detected=$(grep -oP '(?<=use constant APIVER => )\d+' "$storage_pm" 2>/dev/null | head -1)
        [ -n "$detected" ] && STORAGE_APIVER="$detected"
    fi

    log "Detected: PVE $PVE_FULL (Storage API version: $STORAGE_APIVER)"

    if [[ "$PVE_MAJOR" =~ ^[0-9]+$ ]] && [ "$PVE_MAJOR" -lt 7 ]; then
        warn "PVE $PVE_FULL may be too old (< 7.0). Proceeding anyway..."
    fi
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

detect_pve_info

log "Installing Proxmox iSCSI Multipath Storage Plugin..."

# Install dependencies first
log "Installing dependencies..."
"$SCRIPT_DIR/scripts/iscsi-install-deps.sh"

# Create plugin directory
log "Creating plugin directory..."
mkdir -p "$PLUGIN_DIR"

# Install plugin
log "Installing ISCSIMultipathPlugin.pm..."
cp "$SCRIPT_DIR/src/PVE/Storage/Custom/ISCSIMultipathPlugin.pm" "$PLUGIN_DIR/"

# Patch APIVER to match the installed PVE's Storage API version (capped at our max)
PLUGIN_MAX_APIVER=14
if [[ "$STORAGE_APIVER" =~ ^[0-9]+$ ]] && [ "$STORAGE_APIVER" -lt "$PLUGIN_MAX_APIVER" ]; then
    log "  Adjusting plugin APIVER: $PLUGIN_MAX_APIVER -> $STORAGE_APIVER (PVE $PVE_FULL)"
    sed -i "s/use constant APIVER => [0-9]\+;/use constant APIVER => $STORAGE_APIVER;/" \
        "$PLUGIN_DIR/ISCSIMultipathPlugin.pm"
else
    log "  Plugin APIVER: $PLUGIN_MAX_APIVER (matches PVE Storage API $STORAGE_APIVER)"
fi

chmod 644 "$PLUGIN_DIR/ISCSIMultipathPlugin.pm"

# Install helper scripts
log "Installing helper scripts..."
cp "$SCRIPT_DIR/scripts/iscsi-connect.sh" "$SCRIPT_INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/iscsi-cluster-sync.sh" "$SCRIPT_INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/iscsi-rescan.sh" "$SCRIPT_INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/iscsi-discover.sh" "$SCRIPT_INSTALL_DIR/"
chmod 755 "$SCRIPT_INSTALL_DIR/iscsi-connect.sh"
chmod 755 "$SCRIPT_INSTALL_DIR/iscsi-cluster-sync.sh"
chmod 755 "$SCRIPT_INSTALL_DIR/iscsi-rescan.sh"
chmod 755 "$SCRIPT_INSTALL_DIR/iscsi-discover.sh"

# Install systemd service
log "Installing systemd service..."
cp "$SCRIPT_DIR/systemd/iscsi-mpath-connect@.service" "$SYSTEMD_DIR/"
systemctl daemon-reload

# Create configuration directory
log "Creating configuration directory..."
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/example.conf" ]; then
    cp "$SCRIPT_DIR/conf/iscsi-mpath-example.conf" "$CONF_DIR/example.conf"
fi

# Configure multipath
log "Configuring multipath..."
configure_multipath() {
    local mpath_conf="/etc/multipath.conf"
    local mpath_conf_backup="/etc/multipath.conf.backup.$(date +%Y%m%d%H%M%S)"
    local our_marker="# Configured by Proxmox iSCSI Multipath Plugin"

    # Check if multipath.conf exists and if it's ours or default
    if [ -f "$mpath_conf" ]; then
        if grep -q "$our_marker" "$mpath_conf"; then
            log "Multipath already configured by this plugin"
            return 0
        fi

        # Check if find_multipaths is already set
        if grep -qE "^\s*find_multipaths\s+" "$mpath_conf"; then
            log "find_multipaths already configured in $mpath_conf"
            # Just ensure the conf.d directory exists
            mkdir -p /etc/multipath/conf.d
            return 0
        fi

        # Backup existing config
        log "Backing up existing multipath.conf to $mpath_conf_backup"
        cp "$mpath_conf" "$mpath_conf_backup"
    fi

    # Install our multipath.conf
    log "Installing multipath.conf with blacklist and find_multipaths=no"
    cp "$SCRIPT_DIR/conf/multipath.conf" "$mpath_conf"

    # Create conf.d directory for per-device overrides
    mkdir -p /etc/multipath/conf.d

    # Create wwids file if it doesn't exist
    if [ ! -f /etc/multipath/wwids ]; then
        echo "# Multipath wwids, Version : 1.0" > /etc/multipath/wwids
        chmod 644 /etc/multipath/wwids
    fi

    # Reload multipathd if running
    if systemctl is-active --quiet multipathd; then
        log "Reconfiguring multipathd..."
        multipathd reconfigure 2>/dev/null || true
    fi
}

configure_multipath

# Restart PVE services to load the plugin
log "Restarting pvedaemon..."
systemctl restart pvedaemon

log "Restarting pvestatd (for cluster status updates)..."
systemctl restart pvestatd

# Install GUI (optional)
if [ -f "$SCRIPT_DIR/www/install-gui.sh" ]; then
    echo ""
    read -p "Install web GUI components? (experimental) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Installing GUI components..."
        bash "$SCRIPT_DIR/www/install-gui.sh"
    else
        log "Skipping GUI installation"
    fi
fi

log ""
log "============================================"
log "Installation complete!"
log "============================================"
log ""
log "Step 1: Add iSCSI Multipath connection:"
log ""
log "  pvesm add iscsimpath my-iscsi-mpath \\"
log "    --iscsi_portal 192.168.1.100,192.168.1.101 \\"
log "    --iscsi_target iqn.2024-01.com.example:storage \\"
log "    --shared 1"
log ""
log "Step 2: Create LVM on multipath device:"
log ""
log "  pvcreate /dev/mapper/mpatha"
log "  vgcreate my-vg /dev/mapper/mpatha"
log ""
log "Step 3: Add LVM storage:"
log ""
log "  pvesm add lvm my-lvm-storage --vgname my-vg --shared 1"
log ""
log "Verify: pvesm status"
log ""
log "Initiator Name: $(grep 'InitiatorName=' /etc/iscsi/initiatorname.iscsi 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
log ""

