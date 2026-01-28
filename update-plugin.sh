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

# Update Perl plugin
PLUGIN_SRC="$SCRIPT_DIR/src/PVE/Storage/Custom/ISCSIMultipathPlugin.pm"
PLUGIN_DST="/usr/share/perl5/PVE/Storage/Custom/ISCSIMultipathPlugin.pm"

if [[ -f "$PLUGIN_SRC" ]]; then
    log "Updating Perl plugin..."
    cp "$PLUGIN_SRC" "$PLUGIN_DST"
    chmod 644 "$PLUGIN_DST"
else
    warn "Plugin source not found: $PLUGIN_SRC"
fi

# Update GUI
GUI_SRC="$SCRIPT_DIR/www/ISCSIMultipathEdit.js"
PVELIB="/usr/share/pve-manager/js/pvemanagerlib.js"
PVELIB_ORIG="/usr/share/pve-manager/js/pvemanagerlib.js.orig"

if [[ -f "$GUI_SRC" ]]; then
    if [[ -f "$PVELIB_ORIG" ]]; then
        log "Updating GUI (rebuilding pvemanagerlib.js)..."
        cat "$PVELIB_ORIG" "$GUI_SRC" > "$PVELIB"
    else
        warn "Original pvemanagerlib.js not found. Run full install first."
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

