#!/bin/bash
# iSCSI Multipath Rescan Script
# Rescans iSCSI sessions for new LUNs and refreshes multipath/LVM
#
# Usage: iscsi-rescan.sh [target-iqn]
#        iscsi-rescan.sh --all
#        iscsi-rescan.sh --storage <storage-id>

set -e

SCRIPT_NAME=$(basename "$0")

usage() {
    echo "Usage: $SCRIPT_NAME [OPTIONS] [IQN]"
    echo ""
    echo "Rescan iSCSI sessions for new LUNs and refresh multipath/LVM."
    echo ""
    echo "Options:"
    echo "  --all              Rescan all iSCSI sessions"
    echo "  --storage NAME     Rescan the target used by storage NAME"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME iqn.2024-01.com.example:storage"
    echo "  $SCRIPT_NAME --all"
    echo "  $SCRIPT_NAME --storage my-iscsi-storage"
    exit 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

rescan_session() {
    local target_iqn="$1"
    local count=0

    log "Rescanning sessions for target: $target_iqn"

    # Get session IDs for this target
    local sessions
    sessions=$(iscsiadm -m session 2>/dev/null | grep "$target_iqn" | awk '{print $2}' | tr -d '[]') || true

    if [ -z "$sessions" ]; then
        error "No active sessions found for target: $target_iqn"
        return 1
    fi

    # Rescan each session
    for sid in $sessions; do
        log "  Rescanning session $sid..."
        iscsiadm -m session -r "$sid" -R 2>/dev/null || true
        ((count++))
    done

    log "  Rescanned $count session(s)"

    # Reconfigure multipathd to pick up new devices
    log "  Reconfiguring multipathd..."
    multipathd reconfigure 2>/dev/null || true

    return 0
}

rescan_all() {
    log "Rescanning all iSCSI sessions..."

    # Rescan all sessions
    iscsiadm -m session -R 2>/dev/null || {
        log "No active sessions to rescan"
        return 0
    }

    # Reconfigure multipathd
    log "Reconfiguring multipathd..."
    multipathd reconfigure 2>/dev/null || true

    log "All sessions rescanned"
}

get_storage_target() {
    local storage_id="$1"

    if [ ! -f /etc/pve/storage.cfg ]; then
        error "Storage config not found: /etc/pve/storage.cfg"
        return 1
    fi

    # Parse storage.cfg to find the target IQN for this storage
    awk -v storage="$storage_id" '
        /^iscsimpath:/ { current = $2 }
        current == storage && /iscsi_target/ { print $2; exit }
    ' /etc/pve/storage.cfg
}

# Parse arguments
if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    -h|--help)
        usage
        ;;
    --all)
        rescan_all
        ;;
    --storage)
        [ -n "$2" ] || { error "Missing storage name"; usage; }
        iqn=$(get_storage_target "$2")
        [ -n "$iqn" ] || { error "Storage '$2' not found or has no target IQN"; exit 1; }
        rescan_session "$iqn"
        ;;
    iqn.*)
        rescan_session "$1"
        ;;
    *)
        error "Unknown option or invalid IQN: $1"
        usage
        ;;
esac

# Always refresh multipath and LVM after rescan
log "Refreshing multipath..."
multipath -r 2>/dev/null || true

log "Refreshing LVM..."
pvscan --cache 2>/dev/null || true
vgscan --cache 2>/dev/null || true

log "Rescan complete. Multipath devices:"
multipath -ll 2>/dev/null | head -20 || echo "  (none found)"

