#!/bin/bash
# iSCSI Multipath Cluster Sync Script
# Syncs multipath devices and LVM metadata across all cluster nodes

set -e

SCRIPT_NAME=$(basename "$0")
LOG_TAG="iscsi-cluster-sync"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# Get list of cluster nodes
get_cluster_nodes() {
    if command -v pvecm &> /dev/null; then
        pvecm nodes 2>/dev/null | awk 'NR>1 {print $3}' | grep -v "^$"
    else
        hostname
    fi
}

# Run multipath reconfigure and pvscan on local node
run_local_sync() {
    log "Syncing multipath and LVM on local node"
    multipathd reconfigure 2>&1 || true
    multipath -r 2>&1 || true
    pvscan --cache 2>&1 || true
    vgscan --mknodes 2>&1 || true
}

# Run sync on remote node via SSH
run_remote_sync() {
    local node=$1
    local local_hostname=$(hostname)

    if [ "$node" = "$local_hostname" ]; then
        return 0
    fi

    log "Syncing multipath and LVM on remote node: $node"
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$node" \
        "multipathd reconfigure && multipath -r && pvscan --cache && vgscan --mknodes" 2>&1 || {
        error "Failed to sync on node $node"
        return 1
    }
}

# Sync across cluster
sync_cluster() {
    log "Starting cluster-wide multipath/LVM sync"

    # First, run locally
    run_local_sync

    # Then sync to all other nodes
    local nodes=$(get_cluster_nodes)
    local failed=0

    for node in $nodes; do
        run_remote_sync "$node" || ((failed++))
    done

    if [ $failed -gt 0 ]; then
        error "Failed to sync $failed node(s)"
        return 1
    fi

    log "Cluster sync completed successfully"
    return 0
}

# Rescan iSCSI and sync cluster
rescan_and_sync() {
    log "Rescanning iSCSI sessions..."
    iscsiadm -m session -R 2>/dev/null || true
    
    sleep 2
    
    sync_cluster
}

# Activate VG on all nodes
activate_vg_cluster() {
    local vgname=$1

    if [ -z "$vgname" ]; then
        error "VG name required"
        return 1
    fi

    log "Activating VG $vgname across cluster"

    local nodes=$(get_cluster_nodes)

    for node in $nodes; do
        local local_hostname=$(hostname)
        if [ "$node" = "$local_hostname" ]; then
            vgchange -aly "$vgname" 2>&1 || true
        else
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$node" \
                "vgchange -aly $vgname" 2>&1 || {
                error "Failed to activate VG on node $node"
            }
        fi
    done
}

# Show multipath status across cluster
show_cluster_status() {
    local nodes=$(get_cluster_nodes)
    
    for node in $nodes; do
        echo "=== Node: $node ==="
        local local_hostname=$(hostname)
        if [ "$node" = "$local_hostname" ]; then
            multipath -ll 2>/dev/null || echo "No multipath devices"
        else
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$node" \
                "multipath -ll" 2>/dev/null || echo "Failed to get status"
        fi
        echo ""
    done
}

# Main
case "${1:-sync}" in
    sync)
        sync_cluster
        ;;
    rescan)
        rescan_and_sync
        ;;
    local)
        run_local_sync
        ;;
    activate)
        shift
        activate_vg_cluster "$@"
        ;;
    status)
        show_cluster_status
        ;;
    *)
        echo "Usage: $SCRIPT_NAME {sync|rescan|local|activate <vgname>|status}"
        exit 1
        ;;
esac

