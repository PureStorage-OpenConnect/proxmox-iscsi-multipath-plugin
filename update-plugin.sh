#!/bin/bash
# Quick update script for plugin development
# Updates plugin files without full reinstall

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[UPDATE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check root
[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

# Detect PVE Storage API version for APIVER compatibility
STORAGE_APIVER=$(grep -oP '(?<=use constant APIVER => )\d+' \
    /usr/share/perl5/PVE/Storage.pm 2>/dev/null | head -1 || echo "13")
PLUGIN_MAX_APIVER=14
log "PVE Storage API version: $STORAGE_APIVER"

# Update Perl plugin
PLUGIN_SRC="$SCRIPT_DIR/src/PVE/Storage/Custom/ISCSIMultipathPlugin.pm"
PLUGIN_DST="/usr/share/perl5/PVE/Storage/Custom/ISCSIMultipathPlugin.pm"

if [[ -f "$PLUGIN_SRC" ]]; then
    log "Updating Perl plugin..."
    cp "$PLUGIN_SRC" "$PLUGIN_DST"
    # Patch APIVER to match PVE's Storage API version (capped at our max)
    if [[ "$STORAGE_APIVER" =~ ^[0-9]+$ ]] && [[ "$STORAGE_APIVER" -lt "$PLUGIN_MAX_APIVER" ]]; then
        warn "Adjusting plugin APIVER: $PLUGIN_MAX_APIVER -> $STORAGE_APIVER"
        sed -i "s/use constant APIVER => [0-9]\+;/use constant APIVER => $STORAGE_APIVER;/" "$PLUGIN_DST"
    fi
    chmod 644 "$PLUGIN_DST"
else
    warn "Plugin source not found: $PLUGIN_SRC"
fi

# Update GUI
GUI_SRC="$SCRIPT_DIR/www/ISCSIMultipathEdit.js"
PVELIB="/usr/share/pve-manager/js/pvemanagerlib.js"
PVELIB_ORIG="/var/lib/iscsi-mpath-plugin/pvemanagerlib.js.original"

MARKER_START="// ========== ISCSI-MPATH-PLUGIN-START =========="
MARKER_END="// ========== ISCSI-MPATH-PLUGIN-END =========="

if [[ -f "$GUI_SRC" ]]; then
    if [[ -f "$PVELIB_ORIG" ]]; then
        log "Updating GUI (rebuilding pvemanagerlib.js from original backup)..."
        {
            cat "$PVELIB_ORIG"
            echo ""
            echo "$MARKER_START"
            cat "$GUI_SRC"
            echo ""
            echo "$MARKER_END"
        } > "$PVELIB"
        log "GUI updated successfully"
    elif [[ -f "$PVELIB" ]] && grep -q "$MARKER_START" "$PVELIB"; then
        log "Updating GUI (replacing existing injection)..."
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$PVELIB"
        {
            echo ""
            echo "$MARKER_START"
            cat "$GUI_SRC"
            echo ""
            echo "$MARKER_END"
        } >> "$PVELIB"
        log "GUI updated successfully"
    else
        warn "No GUI backup or existing injection found. Run install-gui.sh first."
    fi
else
    warn "GUI source not found: $GUI_SRC"
fi

# Update helper scripts
SCRIPT_INSTALL_DIR="/usr/local/bin"
for script in iscsi-connect.sh iscsi-cluster-sync.sh iscsi-rescan.sh iscsi-discover.sh; do
    if [[ -f "$SCRIPT_DIR/scripts/$script" ]]; then
        log "Updating $script..."
        cp "$SCRIPT_DIR/scripts/$script" "$SCRIPT_INSTALL_DIR/"
        chmod 755 "$SCRIPT_INSTALL_DIR/$script"
    fi
done

# Restart pveproxy to pick up changes
log "Restarting pveproxy..."
systemctl restart pveproxy

log "Update complete! Clear browser cache (Ctrl+Shift+R) to see GUI changes."

