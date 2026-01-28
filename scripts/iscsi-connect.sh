#!/bin/bash
# iSCSI Multipath Connection Script
# Connect to iSCSI targets with dm-multipath support

set -e

SCRIPT_NAME=$(basename "$0")
LOG_TAG="iscsi-mpath-connect"

# Default values
PORT=3260
STARTUP="automatic"
HOST_IFACE=""
USERNAME=""
PASSWORD=""

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] -t <target_iqn> -a <address>[,<address>...]

Connect to iSCSI target with dm-multipath support.

Options:
    -t, --target <iqn>          Target IQN (required)
    -a, --address <addr>        Target address(es), comma-separated for multipath
    -p, --port <port>           Target port (default: 3260)
    -I, --host-iface <iface>    Host network interface(s), comma-separated
    -u, --username <user>       CHAP username
    -w, --password <pass>       CHAP password
    -s, --startup <mode>        Startup mode: automatic, manual, onboot (default: automatic)
    -d, --disconnect            Disconnect from target
    -S, --status                Show connection status
    -h, --help                  Show this help

Examples:
    # Connect to single portal
    $SCRIPT_NAME -t iqn.2024-01.com.example:storage -a 192.168.1.100

    # Connect with multipath (two paths)
    $SCRIPT_NAME -t iqn.2024-01.com.example:storage -a 192.168.1.100,192.168.1.101

    # Connect with CHAP authentication
    $SCRIPT_NAME -t iqn.2024-01.com.example:storage -a 192.168.1.100 -u user -w secret

    # Disconnect
    $SCRIPT_NAME -d -t iqn.2024-01.com.example:storage
EOF
    exit 1
}

# Check if multipathd is running
ensure_multipathd() {
    if ! systemctl is-active --quiet multipathd; then
        log "Starting multipathd..."
        systemctl start multipathd
    fi
}

# Create or update iSCSI interface binding
ensure_iscsi_iface() {
    local iface_name=$1
    local net_iface=$2

    # Check if iface exists
    if ! iscsiadm -m iface -I "$iface_name" 2>/dev/null | grep -q "iface\."; then
        log "Creating iSCSI iface $iface_name..."
        iscsiadm -m iface -I "$iface_name" -o new 2>/dev/null || {
            error "Failed to create iSCSI iface $iface_name"
            return 1
        }
    fi

    # Bind to network interface
    log "Binding iface $iface_name to network interface $net_iface..."
    iscsiadm -m iface -I "$iface_name" -o update \
        -n iface.net_ifacename -v "$net_iface" 2>/dev/null || {
        error "Failed to bind iface $iface_name to $net_iface"
        return 1
    }

    return 0
}

# Discover and login to target
connect() {
    local target=$1
    local addresses=$2
    local port=${3:-3260}

    ensure_multipathd

    IFS=',' read -ra ADDRS <<< "$addresses"
    IFS=',' read -ra IFACES <<< "$HOST_IFACE"

    # If interfaces are specified, create iSCSI interface bindings
    local ISCSI_IFACES=()
    if [ ${#IFACES[@]} -gt 0 ]; then
        for net_iface in "${IFACES[@]}"; do
            local iface_name="iface-$net_iface"
            if ensure_iscsi_iface "$iface_name" "$net_iface"; then
                ISCSI_IFACES+=("$iface_name")
            fi
        done
    fi

    # Discover and login
    if [ ${#ISCSI_IFACES[@]} -gt 0 ]; then
        # Interface-bound multipath: discover and login from each interface to each portal
        for addr in "${ADDRS[@]}"; do
            local portal="$addr:$port"
            for iface in "${ISCSI_IFACES[@]}"; do
                log "Discovering targets on $portal via $iface..."
                iscsiadm -m discovery -t sendtargets -p "$portal" -I "$iface" 2>&1 || {
                    error "Discovery failed on $portal via $iface"
                }
            done
        done

        # Configure CHAP and startup, then login for each portal/iface combo
        for addr in "${ADDRS[@]}"; do
            local portal="$addr:$port"
            for iface in "${ISCSI_IFACES[@]}"; do
                # Configure CHAP if provided
                if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
                    log "Configuring CHAP for $portal via $iface..."
                    iscsiadm -m node -T "$target" -p "$portal" -I "$iface" \
                        -o update -n node.session.auth.authmethod -v CHAP 2>/dev/null || true
                    iscsiadm -m node -T "$target" -p "$portal" -I "$iface" \
                        -o update -n node.session.auth.username -v "$USERNAME" 2>/dev/null || true
                    iscsiadm -m node -T "$target" -p "$portal" -I "$iface" \
                        -o update -n node.session.auth.password -v "$PASSWORD" 2>/dev/null || true
                fi

                # Set startup mode
                iscsiadm -m node -T "$target" -p "$portal" -I "$iface" \
                    -o update -n node.startup -v "$STARTUP" 2>/dev/null || true

                # Login
                log "Logging into $target via $portal using $iface..."
                iscsiadm -m node -T "$target" -p "$portal" -I "$iface" -l 2>&1 || {
                    error "Login failed for $portal via $iface"
                }
            done
        done
    else
        # Default: no interface binding
        for addr in "${ADDRS[@]}"; do
            local portal="$addr:$port"
            log "Discovering targets on $portal..."
            iscsiadm -m discovery -t sendtargets -p "$portal" 2>&1 || {
                error "Discovery failed on $portal"
            }
        done

        # Configure CHAP if provided
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            for addr in "${ADDRS[@]}"; do
                local portal="$addr:$port"
                log "Configuring CHAP authentication for $portal..."
                iscsiadm -m node -T "$target" -p "$portal" \
                    -o update -n node.session.auth.authmethod -v CHAP 2>/dev/null || true
                iscsiadm -m node -T "$target" -p "$portal" \
                    -o update -n node.session.auth.username -v "$USERNAME" 2>/dev/null || true
                iscsiadm -m node -T "$target" -p "$portal" \
                    -o update -n node.session.auth.password -v "$PASSWORD" 2>/dev/null || true
            done
        fi

        # Set startup mode
        for addr in "${ADDRS[@]}"; do
            local portal="$addr:$port"
            iscsiadm -m node -T "$target" -p "$portal" \
                -o update -n node.startup -v "$STARTUP" 2>/dev/null || true
        done

        # Login to each portal
        for addr in "${ADDRS[@]}"; do
            local portal="$addr:$port"
            log "Logging into $target via $portal..."
            iscsiadm -m node -T "$target" -p "$portal" -l 2>&1 || {
                error "Login failed for $portal"
            }
        done
    fi

    # Wait for devices
    sleep 2

    # Register WWIDs for multipath (critical when find_multipaths=yes/strict)
    register_wwids "$target"

    # Reconfigure multipathd
    log "Reconfiguring multipathd..."
    multipathd reconfigure 2>/dev/null || true

    # Wait for multipath devices to settle
    sleep 1

    log "Connection complete"
    show_status
}

# Register WWIDs for SCSI devices to ensure multipath claims them
# This is critical when find_multipaths is set to 'yes' or 'strict' in multipath.conf
register_wwids() {
    local target=$1

    log "Registering WWIDs for multipath..."

    # Get SCSI devices for this target
    local devices
    devices=$(iscsiadm -m session -P 3 2>/dev/null | \
        awk -v target="$target" '
            /Target:/ { in_target = ($2 == target) }
            in_target && /Attached scsi disk/ { print $4 }
        ')

    if [ -z "$devices" ]; then
        log "No SCSI devices found for target"
        return
    fi

    # Ensure /etc/multipath directory exists
    mkdir -p /etc/multipath

    for dev in $devices; do
        local dev_path="/dev/$dev"
        [ -b "$dev_path" ] || continue

        # Use multipath -a to add device WWID to /etc/multipath/wwids
        # This is the official way to register a device
        log "Registering WWID for $dev..."
        multipath -a "$dev_path" 2>/dev/null || true

        # Also try to get WWID and add manually as backup
        local wwid=""

        # Try /sys/block/<dev>/device/wwid
        if [ -f "/sys/block/$dev/device/wwid" ]; then
            wwid=$(cat "/sys/block/$dev/device/wwid" 2>/dev/null | sed 's/^[^.]*\.//')
        fi

        # Try scsi_id if available
        if [ -z "$wwid" ] && command -v /lib/udev/scsi_id &>/dev/null; then
            wwid=$(/lib/udev/scsi_id -g -u -d "$dev_path" 2>/dev/null)
        fi

        # Add to wwids file if we got a WWID
        if [ -n "$wwid" ]; then
            local wwids_file="/etc/multipath/wwids"
            if ! grep -q "/$wwid/" "$wwids_file" 2>/dev/null; then
                echo "/$wwid/" >> "$wwids_file"
                log "Added WWID $wwid to wwids file"
            fi
        fi
    done
}

# Disconnect from target
disconnect() {
    local target=$1
    log "Disconnecting from $target..."
    iscsiadm -m node -T "$target" -u 2>&1 || {
        error "Disconnect failed for $target"
        return 1
    }
    
    # Reconfigure multipathd
    multipathd reconfigure 2>/dev/null || true
    
    log "Disconnected successfully"
}

# Show status
show_status() {
    echo "=== iSCSI Sessions ==="
    iscsiadm -m session 2>/dev/null || echo "No active sessions"
    echo ""
    echo "=== Multipath Devices ==="
    multipath -ll 2>/dev/null || echo "No multipath devices"
}

# Parse arguments
TARGET=""
ADDRESSES=""
DO_DISCONNECT=0
DO_STATUS=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--target) TARGET="$2"; shift 2 ;;
        -a|--address) ADDRESSES="$2"; shift 2 ;;
        -p|--port) PORT="$2"; shift 2 ;;
        -I|--host-iface) HOST_IFACE="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -w|--password) PASSWORD="$2"; shift 2 ;;
        -s|--startup) STARTUP="$2"; shift 2 ;;
        -d|--disconnect) DO_DISCONNECT=1; shift ;;
        -S|--status) DO_STATUS=1; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

# Execute
if [ $DO_STATUS -eq 1 ]; then
    show_status
    exit 0
fi

if [ -z "$TARGET" ]; then
    error "Target IQN is required"
    usage
fi

if [ $DO_DISCONNECT -eq 1 ]; then
    disconnect "$TARGET"
else
    if [ -z "$ADDRESSES" ]; then
        error "Target address is required"
        usage
    fi
    connect "$TARGET" "$ADDRESSES" "$PORT"
fi

