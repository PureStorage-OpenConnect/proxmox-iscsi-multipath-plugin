#!/bin/bash
# iSCSI Target Discovery Helper Script
# Discovers available iSCSI targets on specified portal(s)

set -e

PORTAL=""
PORT=3260
OUTPUT_FORMAT="text"

usage() {
    echo "Usage: $0 -p <portal> [-P <port>] [-j]"
    echo ""
    echo "Options:"
    echo "  -p <portal>   iSCSI portal IP/hostname (required, comma-separated for multiple)"
    echo "  -P <port>     iSCSI port (default: 3260)"
    echo "  -j            Output in JSON format"
    echo "  -h            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -p 192.168.1.100"
    echo "  $0 -p 192.168.1.100,192.168.1.101 -j"
    exit 1
}

while getopts "p:P:jh" opt; do
    case $opt in
        p) PORTAL="$OPTARG" ;;
        P) PORT="$OPTARG" ;;
        j) OUTPUT_FORMAT="json" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$PORTAL" ]; then
    echo "Error: Portal is required" >&2
    usage
fi

# Check for iscsiadm
if ! command -v iscsiadm &>/dev/null; then
    echo "Error: iscsiadm not found. Install open-iscsi package." >&2
    exit 1
fi

# Split portals
IFS=',' read -ra PORTALS <<< "$PORTAL"

# Discover targets on each portal
declare -A TARGETS

for p in "${PORTALS[@]}"; do
    portal_addr="$p:$PORT"
    
    # Run discovery
    output=$(iscsiadm -m discovery -t sendtargets -p "$portal_addr" 2>/dev/null || true)
    
    # Parse output
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^[:space:]]+[[:space:]]+(iqn\.[^[:space:]]+)$ ]]; then
            iqn="${BASH_REMATCH[1]}"
            if [ -z "${TARGETS[$iqn]}" ]; then
                TARGETS[$iqn]="$p"
            else
                TARGETS[$iqn]="${TARGETS[$iqn]},$p"
            fi
        fi
    done <<< "$output"
done

# Output results
if [ ${#TARGETS[@]} -eq 0 ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        echo '{"targets":[]}'
    else
        echo "No targets discovered"
    fi
    exit 0
fi

if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo -n '{"targets":['
    first=1
    for iqn in "${!TARGETS[@]}"; do
        if [ $first -eq 0 ]; then
            echo -n ","
        fi
        first=0
        portals="${TARGETS[$iqn]}"
        echo -n "{\"iqn\":\"$iqn\",\"portals\":\"$portals\"}"
    done
    echo ']}'
else
    echo "Discovered targets:"
    for iqn in "${!TARGETS[@]}"; do
        portals="${TARGETS[$iqn]}"
        echo "  $iqn"
        echo "    Portals: $portals"
    done
fi

