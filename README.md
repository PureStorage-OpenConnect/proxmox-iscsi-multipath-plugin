# Proxmox iSCSI Multipath Storage Plugin

A custom storage plugin for Proxmox VE that provides iSCSI multipath connectivity with full GUI integration. The plugin automates iSCSI interface binding, discovery, login, and multipath device management.

## Features

- **Multipath Support**: Connect to iSCSI targets via multiple network interfaces for redundancy and performance
- **Interface Binding**: Bind iSCSI sessions to specific network interfaces (VLANs, bonds, etc.)
- **GUI Integration**: Full web interface support with target discovery
- **Automatic Vendor Whitelisting**: Automatically adds storage vendors to multipath blacklist exceptions
- **CHAP Authentication**: Optional CHAP username/password support
- **Multipath Policy Configuration**: Configure path selection algorithms per-storage

## Requirements

- Proxmox VE 7.x or 8.x
- `open-iscsi` package
- `multipath-tools` package

## Installation

```bash
git clone https://github.com/YOUR_REPO/proxmox-iscsi-multipath-plugin.git
cd proxmox-iscsi-multipath-plugin
sudo ./install.sh
```

The installer will:
1. Install dependencies (open-iscsi, multipath-tools)
2. Install the plugin to `/usr/share/perl5/PVE/Storage/Custom/`
3. Configure `/etc/multipath.conf` with vendor whitelisting
4. Optionally install GUI components

## Configuration

### Via GUI

1. Go to **Datacenter → Storage → Add → iSCSI Multipath**
2. Enter portal address(es), comma-separated for multiple portals
3. Click **Discover** to find targets, or enter target IQN manually
4. Optionally specify host interfaces for multipath (e.g., `eth0,eth1`)
5. Click **Add**

### Via CLI

```bash
pvesm add iscsimpath my-storage \
    --iscsi_portal PORTAL1_IP,PORTAL2_IP \
    --iscsi_target iqn.2010-06.com.example:target1 \
    --iscsi_host_iface eth0,eth1 \
    --shared 1
```

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `iscsi_portal` | Portal IP address(es), comma-separated | Required |
| `iscsi_target` | Target IQN(s), comma-separated | Auto-discover |
| `iscsi_port` | iSCSI port | 3260 |
| `iscsi_host_iface` | Host network interface(s) for multipath | None |
| `iscsi_username` | CHAP username | None |
| `iscsi_password` | CHAP password | None |
| `iscsi_startup` | Startup mode: automatic, manual, onboot | automatic |
| `mpath_policy` | Path grouping: failover, multibus, group_by_prio | System default |
| `mpath_selector` | Path selector: round-robin, queue-length, service-time | System default |
| `mpath_no_path_retry` | Behavior when all paths fail | System default |

## What the Plugin Does (Manual Equivalent)

The plugin automates the following steps. Here's what you would run manually:

### Step 1: Create iSCSI Interface Bindings

For each host interface, create an iSCSI interface that binds sessions to that NIC:

```bash
# Create iSCSI interface for first NIC
iscsiadm -m iface -I iface-eth0 -o new
iscsiadm -m iface -I iface-eth0 -o update \
    -n iface.net_ifacename -v eth0

# Create iSCSI interface for second NIC
iscsiadm -m iface -I iface-eth1 -o new
iscsiadm -m iface -I iface-eth1 -o update \
    -n iface.net_ifacename -v eth1

# Verify interfaces
iscsiadm -m iface
```

### Step 2: Discover Targets

Run discovery on each portal to find available targets:

```bash
# Discover targets on first portal
iscsiadm -m discovery -t sendtargets -p PORTAL1_IP:3260

# Discover targets on second portal
iscsiadm -m discovery -t sendtargets -p PORTAL2_IP:3260

# List discovered node records
iscsiadm -m node
```

### Step 3: Configure Authentication (Optional)

If CHAP authentication is required:

```bash
TARGET="iqn.2010-06.com.example:target1"
PORTAL="PORTAL1_IP:3260"

iscsiadm -m node -T $TARGET -p $PORTAL \
    -o update -n node.session.auth.authmethod -v CHAP
iscsiadm -m node -T $TARGET -p $PORTAL \
    -o update -n node.session.auth.username -v myuser
iscsiadm -m node -T $TARGET -p $PORTAL \
    -o update -n node.session.auth.password -v mypassword
```

### Step 4: Set Startup Mode

```bash
iscsiadm -m node -T $TARGET -p $PORTAL \
    -o update -n node.startup -v automatic
```

### Step 5: Login with Interface Binding

Login to each portal using each interface to create multiple paths:

```bash
TARGET="iqn.2010-06.com.example:target1"

# Login to portal 1 via interface 1
iscsiadm -m node -T $TARGET -p PORTAL1_IP:3260 -I iface-eth0 -l

# Login to portal 1 via interface 2
iscsiadm -m node -T $TARGET -p PORTAL1_IP:3260 -I iface-eth1 -l

# Login to portal 2 via interface 1
iscsiadm -m node -T $TARGET -p PORTAL2_IP:3260 -I iface-eth0 -l

# Login to portal 2 via interface 2
iscsiadm -m node -T $TARGET -p PORTAL2_IP:3260 -I iface-eth1 -l

# Verify sessions (should show 4 sessions for 2 portals × 2 interfaces)
iscsiadm -m session
```

### Step 6: Verify Multipath

```bash
# Rescan for new devices
multipathd reconfigure

# Show multipath topology
multipath -ll
```

### Step 7: Create LVM on Multipath Device (Optional)

```bash
# Find the multipath device
multipath -ll
# Look for device like /dev/mapper/3624a9370abc123...

# Create physical volume
pvcreate /dev/mapper/3624a9370abc123def456

# Create volume group
vgcreate vg_3624a9370abc123def456 /dev/mapper/3624a9370abc123def456

# Verify
vgs
pvs
```

## Disconnecting / Cleanup

To manually disconnect and clean up:

```bash
TARGET="iqn.2010-06.com.example:target1"

# Logout all sessions for target
iscsiadm -m node -T $TARGET -u

# Delete node records
iscsiadm -m node -T $TARGET -o delete

# Delete iSCSI interfaces (if no longer needed)
iscsiadm -m iface -I iface-eth0 -o delete
iscsiadm -m iface -I iface-eth1 -o delete

# Reconfigure multipath to remove stale devices
multipathd reconfigure
```

## Multipath Configuration

The plugin installs `/etc/multipath.conf` with:

- **Blacklist all devices by default** - prevents local disks from being multipathd
- **Whitelist common storage vendors** - Pure Storage, NetApp, EMC, Dell, HPE, etc.
- **Default path selector**: `service-time` for optimal performance
- **Default failover policy**: One active path, others on standby

If your storage vendor isn't whitelisted, the plugin will automatically add it when connecting.

### Checking Multipath Status

```bash
# Show all multipath devices with paths
multipath -ll

# Show path status
multipathd show paths

# Show multipath topology
multipathd show topology
```

## Troubleshooting

### View Plugin Logs

```bash
# Watch logs in real-time
journalctl -f -u pvedaemon | grep "iSCSI Multipath"

# View recent logs
journalctl -u pvedaemon --since "10 minutes ago" | grep -i iscsi
```

### Common Issues

**Login fails with "No records found"**
- Run discovery first: `iscsiadm -m discovery -t sendtargets -p PORTAL:3260`
- Check node records exist: `iscsiadm -m node`

**Multipath device not created**
- Check vendor is whitelisted: `grep -A2 "blacklist_exceptions" /etc/multipath.conf`
- Check multipath status: `multipath -ll`
- Reconfigure: `multipathd reconfigure`

**Interface binding not working**
- Verify interface exists: `ip addr show INTERFACE`
- Check iSCSI interface: `iscsiadm -m iface -I iface-INTERFACE`
- Ensure interface has IP on same subnet as target

**Session shows "no active session"**
- Check network connectivity: `ping -I INTERFACE TARGET_IP`
- Check iSCSI service: `systemctl status iscsid`

## Files Installed

| File | Location |
|------|----------|
| Plugin | `/usr/share/perl5/PVE/Storage/Custom/ISCSIMultipathPlugin.pm` |
| GUI (optional) | Appended to `/usr/share/pve-manager/js/pvemanagerlib.js` |
| Multipath config | `/etc/multipath.conf` |
| Helper scripts | `/usr/local/bin/iscsi-*.sh` |

## Uninstall

```bash
sudo ./uninstall.sh
```

