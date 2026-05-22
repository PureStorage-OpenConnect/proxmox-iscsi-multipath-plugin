package PVE::Storage::Custom::ISCSIMultipathPlugin;

use strict;
use warnings;

use File::stat;
use IO::Dir;
use IO::File;
use File::Path qw(make_path);

use PVE::JSONSchema qw(get_standard_option);
use PVE::Storage::Plugin;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach);

use base qw(PVE::Storage::Plugin);

# Command paths
my $ISCSIADM = '/usr/sbin/iscsiadm';
my $MULTIPATH = '/sbin/multipath';
my $MULTIPATHD = '/sbin/multipathd';

# API Version for plugin compatibility
use constant APIVER => 14;
use constant APIAGE => 0;

sub api {
    return APIVER;
}

my $found_iscsi;
sub assert_iscsi_support {
    my ($noerr) = @_;
    return $found_iscsi if $found_iscsi;

    $found_iscsi = -x $ISCSIADM;

    if (!$found_iscsi) {
        die "error: no iSCSI support - please install open-iscsi\n" if !$noerr;
        warn "warning: no iSCSI support - please install open-iscsi\n";
    }
    return $found_iscsi;
}

my $found_multipath;
sub assert_multipath_support {
    my ($noerr) = @_;
    return $found_multipath if $found_multipath;

    $found_multipath = -x $MULTIPATH && -x $MULTIPATHD;

    if (!$found_multipath) {
        die "error: no multipath support - please install multipath-tools\n" if !$noerr;
        warn "warning: no multipath support - please install multipath-tools\n";
    }
    return $found_multipath;
}

# Get initiator name from system
sub get_initiator_name {
    my $initiator = file_read_firstline('/etc/iscsi/initiatorname.iscsi');
    if ($initiator && $initiator =~ /InitiatorName=(.+)/) {
        return $1;
    }
    return undef;
}

# Get IPv4 address assigned to a network interface
sub get_iface_ip {
    my ($iface) = @_;

    return undef if !$iface;

    my $ip = undef;
    eval {
        my $output = '';
        run_command(
            ['ip', '-4', '-o', 'addr', 'show', $iface],
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            noerr => 1,
        );
        if ($output =~ /inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/) {
            $ip = $1;
        }
    };

    return $ip;
}

# Discover iSCSI targets on a portal
sub iscsi_discover {
    my ($portal, $port) = @_;

    $port //= 3260;
    my $portal_addr = "$portal:$port";

    assert_iscsi_support();

    my @targets;
    eval {
        my $output = '';
        run_command(
            [$ISCSIADM, '-m', 'discovery', '-t', 'sendtargets', '-p', $portal_addr],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            noerr => 1,
        );

        # Parse output: "portal:port,tpgt iqn.xxx"
        for my $line (split /\n/, $output) {
            if ($line =~ /^\S+\s+(iqn\.\S+)$/) {
                my $iqn = $1;
                push @targets, $iqn unless grep { $_ eq $iqn } @targets;
            }
        }
    };

    return @targets;
}

# Discover targets from multiple portals
sub iscsi_discover_all {
    my ($portals, $port) = @_;

    my %targets;
    for my $portal (@$portals) {
        my @discovered = iscsi_discover($portal, $port);
        for my $iqn (@discovered) {
            $targets{$iqn} = 1;
        }
    }

    return keys %targets;
}

# Create or update iSCSI interface binding
# Returns: (success, was_newly_created)
sub ensure_iscsi_iface {
    my ($iface_name, $net_iface) = @_;

    # Check if iface already exists
    my $exists = 0;
    eval {
        my $output = '';
        run_command(
            [$ISCSIADM, '-m', 'iface', '-I', $iface_name],
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            noerr => 1,
        );
        $exists = 1 if $output =~ /iface\./;
    };

    my $newly_created = 0;
    if (!$exists) {
        # Create new iface
        eval {
            run_command([$ISCSIADM, '-m', 'iface', '-I', $iface_name, '-o', 'new']);
        };
        if ($@) {
            warn "Failed to create iSCSI iface $iface_name: $@";
            return (0, 0);
        }
        $newly_created = 1;
    }

    # Bind to network interface
    eval {
        run_command([$ISCSIADM, '-m', 'iface', '-I', $iface_name, '-o', 'update',
            '-n', 'iface.net_ifacename', '-v', $net_iface]);
    };
    if ($@) {
        warn "Failed to bind iface $iface_name to $net_iface: $@";
        # Clean up newly created iface on failure
        if ($newly_created) {
            eval { delete_iscsi_iface($iface_name); };
        }
        return (0, 0);
    }

    return (1, $newly_created);
}

# Delete an iSCSI interface
sub delete_iscsi_iface {
    my ($iface_name) = @_;

    eval {
        run_command([$ISCSIADM, '-m', 'iface', '-I', $iface_name, '-o', 'delete']);
    };
    if ($@) {
        warn "Failed to delete iSCSI iface $iface_name: $@";
        return 0;
    }

    return 1;
}

# Check if any other storages use a given host interface
sub count_storages_using_iface {
    my ($net_iface, $exclude_storeid) = @_;

    my $count = 0;

    eval {
        my $cfg = PVE::Storage::config();
        my $ids = $cfg->{ids};

        for my $storeid (keys %$ids) {
            next if $exclude_storeid && $storeid eq $exclude_storeid;

            my $scfg = $ids->{$storeid};
            next unless $scfg->{type} eq 'iscsimpath';

            my $host_iface = $scfg->{iscsi_host_iface};
            next unless $host_iface;

            # Check if this interface is in the list
            my @ifaces = split(/,/, $host_iface);
            for my $iface (@ifaces) {
                if ($iface eq $net_iface) {
                    $count++;
                    last;
                }
            }
        }
    };

    return $count;
}

# Helper to clean up newly created interfaces on failure
# These are interfaces we just created in this operation, so always delete them
sub cleanup_new_ifaces {
    my ($new_ifaces) = @_;
    return unless $new_ifaces && @$new_ifaces;

    for my $iface_name (@$new_ifaces) {
        eval { delete_iscsi_iface($iface_name); };
        if ($@) {
            warn "Failed to clean up iSCSI interface $iface_name: $@";
        } else {
            warn "Cleaned up iSCSI interface $iface_name\n";
        }
    }
}

# Connect to iSCSI target with options
sub iscsi_connect {
    my ($target_iqn, $portals, $options) = @_;

    assert_iscsi_support();
    assert_multipath_support();

    my $port = $options->{port} // 3260;
    my $host_ifaces = $options->{host_iface} ? [ split(/,/, $options->{host_iface}) ] : [];
    my $username = $options->{username};
    my $password = $options->{password};
    my $startup = $options->{startup} // 'automatic';

    # Track newly created interfaces for cleanup on failure
    my @new_ifaces;
    my $connection_failed = 0;
    my $error_msg = '';

    # Build list of iSCSI interface names to use
    my @iscsi_ifaces;
    if (@$host_ifaces) {
        warn "iSCSI Multipath: Creating interfaces for host_ifaces: " . join(', ', @$host_ifaces) . "\n";
        # Create/update iSCSI interface bindings for each network interface
        for my $net_iface (@$host_ifaces) {
            my $iface_name = "iface-$net_iface";
            warn "iSCSI Multipath: Ensuring iface '$iface_name' for '$net_iface'\n";
            my ($success, $newly_created) = ensure_iscsi_iface($iface_name, $net_iface);
            warn "iSCSI Multipath: ensure_iscsi_iface result: success=$success, newly_created=$newly_created\n";
            if ($success) {
                push @iscsi_ifaces, $iface_name;
                push @new_ifaces, $iface_name if $newly_created;
            } else {
                warn "iSCSI Multipath: Failed to create iface '$iface_name'\n";
            }
        }
        warn "iSCSI Multipath: iscsi_ifaces = [" . join(', ', @iscsi_ifaces) . "]\n";
        warn "iSCSI Multipath: new_ifaces = [" . join(', ', @new_ifaces) . "]\n";
    }

    # Discover and login: if interfaces specified, do it per-interface for multipath
    if (@iscsi_ifaces) {
        # Discovery phase: run discovery ONCE per portal (without interface binding)
        # This creates node records that we can then login to with different interfaces
        my $discovery_success_count = 0;
        my @discovery_errors;
        for my $portal (@$portals) {
            my $portal_addr = "$portal:$port";
            warn "iSCSI Multipath: Discovery on $portal_addr\n";
            eval {
                run_command([$ISCSIADM, '-m', 'discovery', '-t', 'sendtargets', '-p', $portal_addr]);
            };
            if ($@) {
                warn "iSCSI Multipath: Discovery on $portal_addr FAILED: $@";
                push @discovery_errors, "Discovery failed on $portal_addr";
            } else {
                warn "iSCSI Multipath: Discovery on $portal_addr succeeded\n";
                $discovery_success_count++;
            }
        }

        # If all discoveries failed, clean up and fail
        if ($discovery_success_count == 0) {
            cleanup_new_ifaces(\@new_ifaces);
            die "All discoveries failed: " . join("; ", @discovery_errors);
        }
        warn "iSCSI Multipath: $discovery_success_count discovery(s) succeeded\n";

        # Get all discovered portals for this target (target may advertise more portals)
        my @discovered_portals;
        eval {
            my $output = '';
            run_command(
                [$ISCSIADM, '-m', 'node', '-T', $target_iqn],
                outfunc => sub { $output .= shift . "\n"; },
                errfunc => sub { },
                noerr => 1,
            );
            for my $line (split /\n/, $output) {
                # Format: "portal:port,tpgt target_iqn"
                if ($line =~ /^(\S+:\d+),\d+\s+/) {
                    push @discovered_portals, $1;
                }
            }
        };

        # If no portals found from node records, fall back to the portals we were given
        if (!@discovered_portals) {
            warn "iSCSI Multipath: No portals from node records, using configured portals\n";
            @discovered_portals = map { "$_:$port" } @$portals;
        }
        warn "iSCSI Multipath: Using portals: " . join(', ', @discovered_portals) . "\n";

        # Login phase: login to each portal with each interface
        # This creates multiple sessions (one per portal/interface combo) for multipath
        my $login_success_count = 0;
        my @login_errors;
        for my $portal_addr (@discovered_portals) {
            for my $iface (@iscsi_ifaces) {
                # Configure authentication if provided (update the node record)
                if ($username && $password) {
                    eval {
                        run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                            '-o', 'update', '-n', 'node.session.auth.authmethod', '-v', 'CHAP']);
                        run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                            '-o', 'update', '-n', 'node.session.auth.username', '-v', $username]);
                        run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                            '-o', 'update', '-n', 'node.session.auth.password', '-v', $password]);
                    };
                    warn "Failed to configure auth for $portal_addr: $@" if $@;
                }

                # Set startup mode
                eval {
                    run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                        '-o', 'update', '-n', 'node.startup', '-v', $startup]);
                };

                # Login using this interface
                # The -I flag binds the session to the interface even if the node record
                # was discovered without interface binding
                warn "iSCSI Multipath: Login to $portal_addr via $iface\n";
                eval {
                    run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                        '-I', $iface, '-l']);
                };
                if ($@) {
                    warn "iSCSI Multipath: Login to $portal_addr via $iface failed: $@";
                    push @login_errors, "Login failed to $portal_addr via $iface";
                } else {
                    $login_success_count++;
                    warn "iSCSI Multipath: Login to $portal_addr via $iface succeeded\n";
                }
            }
        }

        # For multipath, we only fail if NO logins succeeded
        if ($login_success_count == 0) {
            $connection_failed = 1;
            $error_msg = "All logins failed: " . join("; ", @login_errors);
        } else {
            warn "iSCSI Multipath: $login_success_count login(s) succeeded\n";
        }
    } else {
        # No specific interfaces - use default behavior
        for my $portal (@$portals) {
            my $portal_addr = "$portal:$port";
            eval {
                run_command([$ISCSIADM, '-m', 'discovery', '-t', 'sendtargets', '-p', $portal_addr]);
            };
            if ($@) {
                warn "Discovery on $portal_addr failed: $@";
                $connection_failed = 1;
                $error_msg = "Discovery failed on $portal_addr: $@";
            }
        }

        # If discovery failed, die immediately (no interfaces to clean up)
        if ($connection_failed) {
            die $error_msg;
        }

        # Configure authentication if provided
        if ($username && $password) {
            for my $portal (@$portals) {
                my $portal_addr = "$portal:$port";
                eval {
                    run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                        '-o', 'update', '-n', 'node.session.auth.authmethod', '-v', 'CHAP']);
                    run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                        '-o', 'update', '-n', 'node.session.auth.username', '-v', $username]);
                    run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                        '-o', 'update', '-n', 'node.session.auth.password', '-v', $password]);
                };
                warn "Failed to configure auth for $portal_addr: $@" if $@;
            }
        }

        # Set startup mode and login
        my $login_success_count = 0;
        my @login_errors;
        for my $portal (@$portals) {
            my $portal_addr = "$portal:$port";
            eval {
                run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr,
                    '-o', 'update', '-n', 'node.startup', '-v', $startup]);
            };

            eval {
                run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-p', $portal_addr, '-l']);
            };
            if ($@) {
                warn "iSCSI login to $portal_addr failed: $@";
                push @login_errors, "Login failed to $portal_addr";
            } else {
                $login_success_count++;
            }
        }

        # Only fail if NO logins succeeded
        if ($login_success_count == 0) {
            $connection_failed = 1;
            $error_msg = "All logins failed: " . join("; ", @login_errors);
        }
    }

    # If all logins failed, clean up new interfaces and fail
    if ($connection_failed) {
        cleanup_new_ifaces(\@new_ifaces);
        die $error_msg;
    }

    # Configure multipath for the new devices
    configure_multipath_for_target($target_iqn);
}

# Get vendor/product for a SCSI device
sub get_device_vendor_product {
    my ($dev) = @_;

    my $vendor = '';
    my $product = '';

    my $vendor_path = "/sys/block/$dev/device/vendor";
    my $model_path = "/sys/block/$dev/device/model";

    if (-f $vendor_path) {
        $vendor = file_read_firstline($vendor_path);
        $vendor = trim($vendor) if $vendor;
    }

    if (-f $model_path) {
        $product = file_read_firstline($model_path);
        $product = trim($product) if $product;
    }

    return ($vendor, $product);
}

# Check if vendor is in multipath.conf blacklist_exceptions
sub is_vendor_whitelisted {
    my ($vendor) = @_;

    my $conf_file = '/etc/multipath.conf';
    return 0 unless -f $conf_file;

    my $content = '';
    eval {
        open(my $fh, '<', $conf_file);
        if ($fh) {
            local $/;
            $content = <$fh>;
            close($fh);
        }
    };

    # Check if vendor is in blacklist_exceptions
    # Look for: device { vendor "VENDORNAME" ... }
    return 1 if $content =~ /blacklist_exceptions\s*\{[^}]*device\s*\{[^}]*vendor\s+"\Q$vendor\E"/s;

    return 0;
}

# Add vendor/product to multipath.conf blacklist_exceptions
sub add_vendor_to_whitelist {
    my ($vendor, $product) = @_;

    my $conf_file = '/etc/multipath.conf';
    return 0 unless -f $conf_file;

    my $content = '';
    eval {
        open(my $fh, '<', $conf_file);
        if ($fh) {
            local $/;
            $content = <$fh>;
            close($fh);
        }
    };
    return 0 unless $content;

    # Find the blacklist_exceptions block and add the new device entry
    # Insert after the opening brace of blacklist_exceptions
    my $new_entry = qq{
    # Auto-added by iSCSI Multipath Plugin
    device {
        vendor "$vendor"
        product ".*"
    }};

    if ($content =~ s/(blacklist_exceptions\s*\{)/$1$new_entry/s) {
        eval {
            open(my $fh, '>', $conf_file);
            if ($fh) {
                print $fh $content;
                close($fh);
            }
        };
        if ($@) {
            warn "Failed to update multipath.conf: $@";
            return 0;
        }
        return 1;
    }

    return 0;
}

# Get SCSI devices for a target
sub get_target_devices {
    my ($target_iqn) = @_;

    my @scsi_devices;
    eval {
        my $output = '';
        run_command(
            [$ISCSIADM, '-m', 'session', '-P', '3'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            noerr => 1,
        );

        my $current_target = '';
        my $in_target = 0;
        for my $line (split /\n/, $output) {
            if ($line =~ /Target:\s+(\S+)/) {
                $current_target = $1;
                $in_target = ($current_target eq $target_iqn) ? 1 : 0;
            }
            if ($in_target && $line =~ /Attached scsi disk\s+(\S+)/) {
                push @scsi_devices, $1;
            }
        }
    };

    return @scsi_devices;
}

# Reconfigure multipath after iSCSI devices are connected
# Automatically adds new vendors to whitelist if needed
sub configure_multipath_for_target {
    my ($target_iqn) = @_;

    # Give devices time to appear
    sleep(2);

    # Get devices for this target and check if their vendors are whitelisted
    my @devices = get_target_devices($target_iqn);
    my $config_changed = 0;

    for my $dev (@devices) {
        my ($vendor, $product) = get_device_vendor_product($dev);
        next unless $vendor;

        if (!is_vendor_whitelisted($vendor)) {
            warn "Adding vendor '$vendor' to multipath whitelist\n";
            if (add_vendor_to_whitelist($vendor, $product)) {
                $config_changed = 1;
            }
        }
    }

    # Reconfigure multipathd to pick up new devices
    eval { run_command([$MULTIPATHD, 'reconfigure']); };
    warn "multipathd reconfigure failed: $@" if $@;

    # Additional settle time for multipath devices to be created
    sleep(1);
}

# LVM command paths
my $PVCREATE = '/sbin/pvcreate';
my $VGCREATE = '/sbin/vgcreate';
my $PVS = '/sbin/pvs';
my $VGS = '/sbin/vgs';
my $BLKID = '/sbin/blkid';

# Check if a device is empty (no filesystem, partition table, or LVM)
sub is_device_empty {
    my ($dev_path) = @_;

    return 0 unless -b $dev_path;

    # Check with blkid - if it returns anything, device is not empty
    my $has_content = 0;
    eval {
        my $output = '';
        my $rc = run_command(
            [$BLKID, '-p', $dev_path],
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            noerr => 1,
        );
        # blkid returns 0 if it finds something, 2 if device is empty
        $has_content = 1 if $output =~ /\S/;
    };

    return !$has_content;
}

# Check if device is already a PV
sub is_device_pv {
    my ($dev_path) = @_;

    my $is_pv = 0;
    eval {
        my $output = '';
        run_command(
            [$PVS, '--noheadings', '-o', 'pv_name', $dev_path],
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            noerr => 1,
        );
        $is_pv = 1 if $output =~ /\S/;
    };

    return $is_pv;
}

# Get WWN/WWID for a multipath device
sub get_mpath_wwid {
    my ($mpath_dev) = @_;

    # Extract name from /dev/mapper/NAME
    my $name = $mpath_dev;
    $name =~ s|^/dev/mapper/||;

    # The name is often the WWID itself for multipath
    # Also try to get from multipathd
    my $wwid = $name;

    eval {
        my $output = '';
        run_command(
            [$MULTIPATHD, 'show', 'maps', 'raw', 'format', '%w %n'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            noerr => 1,
        );
        for my $line (split /\n/, $output) {
            my ($w, $n) = split /\s+/, $line;
            if ($n && $n eq $name) {
                $wwid = $w;
                last;
            }
        }
    };

    return $wwid;
}

# Create LVM PV and VG on a multipath device
# VG name is based on WWN
sub create_lvm_on_device {
    my ($mpath_dev) = @_;

    return 0 unless -b $mpath_dev;

    # Check if device is empty
    if (!is_device_empty($mpath_dev)) {
        warn "Device $mpath_dev is not empty, skipping LVM creation\n";
        return 0;
    }

    # Check if already a PV
    if (is_device_pv($mpath_dev)) {
        warn "Device $mpath_dev is already a PV, skipping\n";
        return 0;
    }

    # Get WWID for VG name
    my $wwid = get_mpath_wwid($mpath_dev);
    unless ($wwid) {
        warn "Could not determine WWID for $mpath_dev\n";
        return 0;
    }

    # Sanitize WWID for use as VG name (replace invalid chars)
    my $vg_name = $wwid;
    $vg_name =~ s/[^a-zA-Z0-9_]/_/g;

    # Check if VG already exists
    my $vg_exists = 0;
    eval {
        my $output = '';
        run_command(
            [$VGS, '--noheadings', '-o', 'vg_name', $vg_name],
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            noerr => 1,
        );
        $vg_exists = 1 if $output =~ /\S/;
    };

    if ($vg_exists) {
        warn "VG $vg_name already exists, skipping\n";
        return 0;
    }

    # Create PV
    eval {
        run_command([$PVCREATE, '-f', $mpath_dev]);
    };
    if ($@) {
        warn "Failed to create PV on $mpath_dev: $@\n";
        return 0;
    }

    # Create VG with WWN as name
    eval {
        run_command([$VGCREATE, $vg_name, $mpath_dev]);
    };
    if ($@) {
        warn "Failed to create VG $vg_name on $mpath_dev: $@\n";
        return 0;
    }

    warn "Created VG '$vg_name' on $mpath_dev\n";
    return 1;
}

# Setup LVM on multipath devices for a target (local node only)
sub setup_auto_lvm {
    my ($target_iqn) = @_;

    # Get multipath devices for this target
    my @mpath_devices = get_mpath_devices($target_iqn);

    for my $mpath_dev (@mpath_devices) {
        create_lvm_on_device($mpath_dev);
    }
}

# Disconnect from iSCSI target
sub iscsi_disconnect {
    my ($target_iqn) = @_;

    assert_iscsi_support();

    # Logout from all sessions for this target
    eval {
        run_command([$ISCSIADM, '-m', 'node', '-T', $target_iqn, '-u']);
    };
    warn "iSCSI logout failed: $@" if $@;
}

# Rescan iSCSI sessions for new LUNs
sub iscsi_rescan {
    my ($target_iqn) = @_;

    assert_iscsi_support();

    # Rescan all sessions for this target
    eval {
        run_command([$ISCSIADM, '-m', 'session', '-R']);
    };
    warn "iSCSI rescan failed: $@" if $@;

    # Reconfigure multipathd
    eval { run_command([$MULTIPATHD, 'reconfigure']); };

    # Wait for devices to settle
    sleep(2);

    return 1;
}

# Count how many storages use a given iSCSI target IQN
sub count_storages_using_target {
    my ($target_iqn, $exclude_storeid) = @_;

    my $count = 0;

    my $cfg_file = '/etc/pve/storage.cfg';
    return 0 unless -f $cfg_file;

    my $raw = PVE::Tools::file_get_contents($cfg_file);
    my @lines = split(/\n/, $raw);

    my $current_storeid;
    my $current_type;

    for my $line (@lines) {
        if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
            $current_type = $1;
            $current_storeid = $2;
        }
        elsif ($line =~ m/^\s+iscsi_target\s+(.+?)\s*$/) {
            my $targets_str = $1;
            if ($current_type eq 'iscsimpath' &&
                (!$exclude_storeid || $current_storeid ne $exclude_storeid)) {
                # Check if target_iqn is in the comma-separated list
                my @targets = split(/,/, $targets_str);
                for my $t (@targets) {
                    if ($t eq $target_iqn) {
                        $count++;
                        last;
                    }
                }
            }
        }
    }

    return $count;
}

# Get multipath device for iSCSI target
sub get_multipath_device {
    my ($target_iqn) = @_;

    my @devices;

    # Find all sessions for this target
    my @sessions;
    eval {
        my $output = '';
        run_command(
            [$ISCSIADM, '-m', 'session', '-P', '3'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
        );

        my $current_target = '';
        my $in_target = 0;
        for my $line (split /\n/, $output) {
            if ($line =~ /Target:\s+(\S+)/) {
                $current_target = $1;
                $in_target = ($current_target eq $target_iqn) ? 1 : 0;
            }
            if ($in_target && $line =~ /Attached scsi disk\s+(\S+)/) {
                push @sessions, $1;
            }
        }
    };

    return () unless @sessions;

    # Now find the multipath device for these SCSI devices
    eval {
        my $output = '';
        run_command(
            [$MULTIPATH, '-ll'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
        );

        my $current_dm = '';
        for my $line (split /\n/, $output) {
            # Match multipath device line: "name (wwid) dm-X vendor,product"
            # Name can be WWID (360060...) or friendly name (mpatha)
            if ($line =~ /^(\S+)\s+\([^)]+\)\s+dm-\d+/) {
                $current_dm = "/dev/mapper/$1";
            }
            # Check if any of our session devices are in this multipath
            for my $sess (@sessions) {
                if ($line =~ /\b$sess\b/) {
                    push @devices, $current_dm if $current_dm && !grep { $_ eq $current_dm } @devices;
                }
            }
        }
    };

    return wantarray ? @devices : $devices[0];
}

# Check if target is connected with active sessions
sub is_connected {
    my ($target_iqn) = @_;

    my $connected = 0;
    eval {
        my $output = '';
        run_command(
            [$ISCSIADM, '-m', 'session'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            noerr => 1,
        );
        $connected = 1 if ($output =~ /\Q$target_iqn\E/);
    };

    return $connected;
}

# Plugin type - using new name since 'iscsi' is already used
sub type {
    return 'iscsimpath';
}

# Plugin properties - expose LUNs as images
sub plugindata {
    return {
        content => [ { images => 1, none => 1 }, { images => 1 } ],
    };
}

# Plugin configuration properties (use iscsi_ prefix to avoid conflicts)
sub properties {
    return {
        iscsi_portal => {
            description => "iSCSI portal address(es), comma-separated for multipath",
            type => 'string',
        },
        iscsi_target => {
            description => "iSCSI target IQN(s), comma-separated for multiple targets. If not specified, will autodiscover from portal",
            type => 'string',
            optional => 1,
        },
        iscsi_port => {
            description => "iSCSI port",
            type => 'integer',
            minimum => 1,
            maximum => 65535,
            default => 3260,
        },
        iscsi_host_iface => {
            description => "Host network interface(s) for iSCSI connections, comma-separated (e.g., 'eth0,eth1'). Creates iSCSI interface bindings to force connections through specific NICs for multipath.",
            type => 'string',
        },
        iscsi_username => {
            description => "CHAP username for authentication",
            type => 'string',
        },
        iscsi_password => {
            description => "CHAP password for authentication",
            type => 'string',
        },
        iscsi_startup => {
            description => "iSCSI node startup mode",
            type => 'string',
            enum => ['automatic', 'manual', 'onboot'],
            default => 'automatic',
        },
        mpath_policy => {
            description => "Multipath path grouping policy. Leave empty to use system defaults from /etc/multipath.conf",
            type => 'string',
            enum => ['failover', 'multibus', 'group_by_prio', 'group_by_node_name'],
            optional => 1,
        },
        mpath_selector => {
            description => "Multipath path selector algorithm. Leave empty to use system defaults from /etc/multipath.conf",
            type => 'string',
            enum => ['round-robin', 'queue-length', 'service-time'],
            optional => 1,
        },
        mpath_no_path_retry => {
            description => "Multipath behavior when all paths fail: 'fail' (immediate I/O error), 'queue' (queue forever), or number of retries. Leave empty to use system defaults",
            type => 'string',
            optional => 1,
        },
        auto_lvm => {
            description => "Automatically create LVM PV and VG on empty multipath devices. VG name will be the device WWN. Only runs on local node.",
            type => 'boolean',
            optional => 1,
            default => 0,
        },
    };
}

# Plugin options
sub options {
    return {
        iscsi_portal => { fixed => 1 },
        iscsi_target => { fixed => 1, optional => 1 },  # Optional - will autodiscover if not set
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        iscsi_port => { optional => 1 },
        iscsi_host_iface => { optional => 1 },
        iscsi_username => { optional => 1 },
        iscsi_password => { optional => 1 },
        iscsi_startup => { optional => 1 },
        mpath_policy => { optional => 1 },
        mpath_selector => { optional => 1 },
        mpath_no_path_retry => { optional => 1 },
        shared => { optional => 1 },
        auto_lvm => { optional => 1 },
    };
}

# Override check_config to handle the 'delete' property from Proxmox API
sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    # Remove 'delete' property if present - it's used by Proxmox to delete optional properties
    # but the base class schema check doesn't recognize it
    my $delete = delete $config->{delete};

    my $res = $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);

    return $res;
}

# Called when storage is added - validate, autodiscover, and test connection
sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    warn "iSCSI Multipath: on_add_hook called for storeid=$storeid\n";

    my $portal = $scfg->{iscsi_portal}
        or die "iscsi_portal is required\n";

    my $port = $scfg->{iscsi_port} // 3260;
    my $portals = parse_portals($portal);

    warn "iSCSI Multipath: portals = [" . join(', ', @$portals) . "], port = $port\n";
    warn "iSCSI Multipath: host_iface = " . ($scfg->{iscsi_host_iface} // 'none') . "\n";

    # If target not specified, try to autodiscover
    if (!$scfg->{iscsi_target}) {
        warn "iSCSI Multipath: No target specified, attempting autodiscovery\n";
        my @targets = iscsi_discover_all($portals, $port);

        if (@targets == 0) {
            die "No iSCSI targets discovered on portal(s): $portal\n";
        } elsif (@targets == 1) {
            # Auto-select the only target
            $scfg->{iscsi_target} = $targets[0];
            warn "Auto-discovered iSCSI target: $targets[0]\n";
        } else {
            # Multiple targets found - list them for user selection
            my $target_list = join("\n  ", @targets);
            die "Multiple iSCSI targets found. Please specify one or more in iscsi_target (comma-separated):\n  $target_list\n";
        }
    }

    # Validate target format (can be comma-separated list)
    my $targets = parse_targets($scfg->{iscsi_target});
    warn "iSCSI Multipath: targets = [" . join(', ', @$targets) . "]\n";

    for my $target (@$targets) {
        if ($target !~ /^iqn\.\d{4}-\d{2}\.\S+:\S+$/ && $target !~ /^eui\.[0-9a-fA-F]{16}$/) {
            warn "Target '$target' may not be a valid IQN format\n";
        }
    }

    # Test connection to all targets - fail if any connection fails
    my $connect_opts = {
        port => $port,
        host_iface => $scfg->{iscsi_host_iface},
        username => $scfg->{iscsi_username},
        password => $scfg->{iscsi_password},
        startup => $scfg->{iscsi_startup} // 'automatic',
    };

    for my $target_iqn (@$targets) {
        warn "iSCSI Multipath: Checking connection for target $target_iqn\n";
        if (!is_connected($target_iqn)) {
            warn "iSCSI Multipath: Target $target_iqn not connected, attempting connection\n";
            # Try to connect - this will die on failure
            eval {
                iscsi_connect($target_iqn, $portals, $connect_opts);
            };
            if ($@) {
                die "Failed to connect to iSCSI target '$target_iqn': $@\n";
            }

            # Verify connection succeeded
            if (!is_connected($target_iqn)) {
                die "Connection to iSCSI target '$target_iqn' failed - target not accessible\n";
            }
            warn "iSCSI Multipath: Target $target_iqn connected successfully\n";
        } else {
            warn "iSCSI Multipath: Target $target_iqn already connected\n";
        }
    }

    warn "iSCSI Multipath: on_add_hook completed successfully\n";
    return;
}

# Called when storage is deleted - disconnect iSCSI and clean up interfaces if no other storages use them
sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    my $targets = parse_targets($scfg->{iscsi_target});

    for my $target_iqn (@$targets) {
        # Check if other storages still use this target
        my $other_users = count_storages_using_target($target_iqn, $storeid);

        if ($other_users > 0) {
            next;
        }

        # Disconnect the iSCSI target if this was the last user
        if (is_connected($target_iqn)) {
            eval { iscsi_disconnect($target_iqn); };
            warn "Failed to disconnect iSCSI target $target_iqn: $@" if $@;
        }
    }

    # Clean up iSCSI interfaces if no other storages use them
    if ($scfg->{iscsi_host_iface}) {
        my @host_ifaces = split(/,/, $scfg->{iscsi_host_iface});

        for my $net_iface (@host_ifaces) {
            $net_iface =~ s/^\s+|\s+$//g;  # trim whitespace
            next unless $net_iface;

            # Check if any other storages use this interface
            my $other_users = count_storages_using_iface($net_iface, $storeid);

            if ($other_users > 0) {
                next;
            }

            # Delete the iSCSI interface binding
            my $iface_name = "iface-$net_iface";
            eval { delete_iscsi_iface($iface_name); };
            if ($@) {
                warn "Failed to delete iSCSI interface $iface_name: $@";
            }
        }
    }

    return;
}

# Parse portal string into array
sub parse_portals {
    my ($portal_str) = @_;
    return [ split(/,/, $portal_str) ];
}

# Parse target string into array (supports comma-separated IQNs)
sub parse_targets {
    my ($target_str) = @_;
    return [] unless $target_str;
    return [ split(/,/, $target_str) ];
}

# Configure multipath policy for a device
sub configure_mpath_policy {
    my ($target_iqn, $options) = @_;

    my $policy = $options->{mpath_policy};
    my $selector = $options->{mpath_selector};
    my $no_path_retry = $options->{mpath_no_path_retry};

    # If no policies are explicitly set, use system defaults (don't create per-device config)
    return unless ($policy || $selector || $no_path_retry);

    # Map selector names to multipathd format
    my $selector_map = {
        'round-robin' => 'round-robin 0',
        'queue-length' => 'queue-length 0',
        'service-time' => 'service-time 0',
    };

    # Get multipath devices for this target
    my @mpath_devices = get_multipath_device($target_iqn);

    for my $mpath_dev (@mpath_devices) {
        my $dev_name = $mpath_dev;
        $dev_name =~ s|.*/||;  # Get just the device name (e.g., mpatha)

        # Get the WWID of the device for multipath.conf
        my $wwid = '';
        for my $dm_block (glob("/sys/block/dm-*")) {
            my $name = file_read_firstline("$dm_block/dm/name");
            if ($name && $name eq $dev_name) {
                my $uuid = file_read_firstline("$dm_block/dm/uuid");
                if ($uuid && $uuid =~ /^mpath-(.+)$/) {
                    $wwid = $1;
                }
                last;
            }
        }

        next unless $wwid;

        # Create/update multipath.conf entry for this device
        my $mpath_conf_dir = '/etc/multipath/conf.d';
        make_path($mpath_conf_dir) unless -d $mpath_conf_dir;

        my $conf_file = "$mpath_conf_dir/iscsi-$dev_name.conf";

        # Build config with only the explicitly set options
        my @config_lines = (
            "# Auto-generated by Proxmox iSCSI Multipath Plugin",
            "# Device: $dev_name, Target: $target_iqn",
            "multipaths {",
            "    multipath {",
            "        wwid \"$wwid\"",
        );

        push @config_lines, "        path_grouping_policy $policy" if $policy;
        push @config_lines, "        path_selector \"" . $selector_map->{$selector} . "\"" if $selector && $selector_map->{$selector};
        push @config_lines, "        no_path_retry $no_path_retry" if $no_path_retry;
        push @config_lines, "        failback immediate" if $policy;  # Only set failback if policy is set

        push @config_lines, (
            "    }",
            "}",
        );

        my $conf_content = join("\n", @config_lines) . "\n";

        eval {
            my $fh = IO::File->new($conf_file, 'w');
            if ($fh) {
                print $fh $conf_content;
                $fh->close();
            }
        };
        warn "Failed to write multipath config $conf_file: $@" if $@;
    }

    # Reconfigure multipathd to apply changes
    eval { run_command([$MULTIPATHD, 'reconfigure']); };
    warn "multipathd reconfigure failed: $@" if $@;
}

# Activate storage - connect to iSCSI target
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    assert_iscsi_support();
    assert_multipath_support();

    my $targets = parse_targets($scfg->{iscsi_target});
    my $portals = parse_portals($scfg->{iscsi_portal});

    my $connected_any = 0;

    # Connect to each target if not already connected
    for my $target_iqn (@$targets) {
        if (!is_connected($target_iqn)) {
            eval {
                iscsi_connect($target_iqn, $portals, {
                    port => $scfg->{iscsi_port} // 3260,
                    host_iface => $scfg->{iscsi_host_iface},
                    username => $scfg->{iscsi_username},
                    password => $scfg->{iscsi_password},
                    startup => $scfg->{iscsi_startup} // 'automatic',
                });
                $connected_any = 1;
            };
            warn "Failed to connect to target $target_iqn: $@" if $@;
        }
    }

    # Wait for multipath devices to appear if we connected to any new targets
    if ($connected_any) {
        my $waited = 0;
        my $max_wait = 10;
        while ($waited < $max_wait) {
            # Check if any dm-* devices are multipath devices
            my $found = 0;
            for my $dm_block (glob("/sys/block/dm-*")) {
                my $uuid = file_read_firstline("$dm_block/dm/uuid");
                if ($uuid && $uuid =~ /^mpath-/) {
                    $found = 1;
                    last;
                }
            }
            last if $found;
            sleep(1);
            $waited++;
        }
        sleep(1);
    }

    # Apply multipath policy configuration for all targets
    for my $target_iqn (@$targets) {
        configure_mpath_policy($target_iqn, {
            mpath_policy => $scfg->{mpath_policy},
            mpath_selector => $scfg->{mpath_selector},
            mpath_no_path_retry => $scfg->{mpath_no_path_retry},
        });
    }

    # Auto-create LVM PV/VG on empty multipath devices (local node only)
    if ($scfg->{auto_lvm} && $connected_any) {
        for my $target_iqn (@$targets) {
            setup_auto_lvm($target_iqn);
        }
    }

    return 1;
}

# Deactivate storage - connection stays up
sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

# Get storage status
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $targets = parse_targets($scfg->{iscsi_target});

    # Check if any target is connected
    for my $target_iqn (@$targets) {
        if (is_connected($target_iqn)) {
            return (0, 0, 0, 1);
        }
    }

    return (0, 0, 0, 0);
}

# Get list of LUNs from iSCSI target via multipath
sub iscsi_lun_list {
    my ($target_iqn) = @_;

    my $res = {};

    # Get multipath devices and their WWIDs
    eval {
        my $output = '';
        run_command(
            [$MULTIPATH, '-ll'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
        );

        my $current_name = '';
        my $current_wwid = '';
        my $current_size = 0;
        my $in_target = 0;

        for my $line (split /\n/, $output) {
            # Match multipath device: "name (wwid) dm-X VENDOR,PRODUCT"
            # Name is either friendly (mpatha) or WWID-based (360060...)
            if ($line =~ /^(\S+)\s+\(([^)]+)\)\s+dm-\d+/) {
                $current_name = $1;
                $current_wwid = $2;

                # Get size from sysfs
                my $dm_name = $current_name;
                my $size_file = "/sys/block/dm-*/dm/name";
                for my $dm_path (glob("/sys/block/dm-*")) {
                    my $dm_check = file_read_firstline("$dm_path/dm/name");
                    if ($dm_check && $dm_check eq $current_name) {
                        my $size_sectors = file_read_firstline("$dm_path/size") // 0;
                        $current_size = $size_sectors * 512;
                        last;
                    }
                }

                # We'll check if this device belongs to our target below
                $in_target = 0;
            }

            # Check if paths include our target's sessions
            # Look for scsi device references
            if ($current_name && $line =~ /\d+:\d+:\d+:\d+\s+(\w+)\s/) {
                my $scsi_dev = $1;
                # Check if this SCSI device belongs to our target
                my $scsi_target = get_scsi_device_target($scsi_dev);
                if ($scsi_target && $scsi_target eq $target_iqn) {
                    $in_target = 1;
                }
            }

            # If we found paths from our target, record this device
            if ($in_target && $current_name && $current_wwid) {
                my $volname = "wwid-$current_wwid";
                $res->{$volname} = {
                    format => 'raw',
                    size => $current_size,
                    vmid => 0,
                    devname => $current_name,
                    wwid => $current_wwid,
                };
            }
        }
    };

    return $res;
}

# Get the iSCSI target IQN for a SCSI device
sub get_scsi_device_target {
    my ($scsi_dev) = @_;

    # Find the session for this device
    my $session_path = "/sys/block/$scsi_dev/device";
    return undef unless -d $session_path;

    # Walk up to find the session
    my $target_iqn = undef;
    eval {
        my $output = '';
        run_command(
            [$ISCSIADM, '-m', 'session', '-P', '3'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
        );

        my $current_target = '';
        for my $line (split /\n/, $output) {
            if ($line =~ /Target:\s+(\S+)/) {
                $current_target = $1;
            }
            if ($line =~ /Attached scsi disk\s+$scsi_dev\s/) {
                $target_iqn = $current_target;
                last;
            }
        }
    };

    return $target_iqn;
}

# Parse volume name (LUN identifier)
sub parse_volname {
    my ($class, $volname) = @_;

    # Format: wwid-xxx, mpath-xxx, or raw WWID (hex string)
    if ($volname =~ m/^(wwid-\S+|mpath\S+|[0-9a-f]{20,})$/i) {
        return ('images', $volname, undef, undef, undef, undef, 'raw');
    }

    die "unable to parse iscsi multipath volume name '$volname'\n";
}

# Get filesystem path for volume (LUN)
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "snapshots not supported on iscsi multipath storage\n" if defined($snapname);

    my $path;
    if ($volname =~ /^wwid-(.+)$/) {
        my $wwid = $1;
        # Try direct mapper path first (for WWID-based names)
        $path = "/dev/mapper/$wwid";
        if (!-e $path) {
            # Fallback to by-id path
            $path = "/dev/disk/by-id/dm-uuid-mpath-$wwid";
        }
        if (!-e $path) {
            # Try to find the device in mapper by scanning
            for my $dm (glob("/dev/mapper/*")) {
                next if $dm =~ /control$/;
                my $dm_wwid = get_dm_wwid($dm);
                if ($dm_wwid && $dm_wwid eq $wwid) {
                    $path = $dm;
                    last;
                }
            }
        }
    } elsif ($volname =~ /^([0-9a-f]{20,})$/i) {
        # Direct WWID (no prefix)
        $path = "/dev/mapper/$volname";
    } elsif ($volname =~ /^mpath(.+)$/) {
        # Friendly name format
        $path = "/dev/mapper/$volname";
    } else {
        die "cannot determine path for volume '$volname'\n";
    }

    return wantarray ? ($path, undef, 'images') : $path;
}

# Get WWID of a device mapper device
sub get_dm_wwid {
    my ($dm_path) = @_;

    my $dm_name = $dm_path;
    $dm_name =~ s|.*/||;

    for my $dm_block (glob("/sys/block/dm-*")) {
        my $name = file_read_firstline("$dm_block/dm/name");
        if ($name && $name eq $dm_name) {
            my $uuid = file_read_firstline("$dm_block/dm/uuid");
            if ($uuid && $uuid =~ /^mpath-(.+)$/) {
                return $1;
            }
        }
    }
    return undef;
}

# List all LUNs as images
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];
    my $targets = parse_targets($scfg->{iscsi_target});

    # Collect LUNs from all connected targets
    my %seen_volnames;
    for my $target_iqn (@$targets) {
        next if !is_connected($target_iqn);

        my $luns = iscsi_lun_list($target_iqn);

        for my $volname (keys %$luns) {
            # Skip duplicates (same LUN visible from multiple targets)
            next if $seen_volnames{$volname};
            $seen_volnames{$volname} = 1;

            my $info = $luns->{$volname};
            my $volid = "$storeid:$volname";

            if ($vollist) {
                my $found = grep { $_ eq $volid } @$vollist;
                next if !$found;
            } else {
                next if defined($vmid);
            }

            push @$res, {
                volid => $volid,
                format => 'raw',
                size => $info->{size},
                vmid => 0,
                content => 'images',
            };
        }
    }

    return $res;
}

# Override list_volumes
sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    my $res = $class->list_images($storeid, $scfg, $vmid);

    for my $item (@$res) {
        $item->{content} = 'images';
    }

    return $res;
}

# Cannot allocate - LUNs are managed by the storage target
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    die "cannot allocate space on iscsi multipath storage - LUNs are managed by the storage target\n";
}

# Cannot free - LUNs are managed by the storage target
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    die "cannot free space on iscsi multipath storage - LUNs are managed by the storage target\n";
}

# Volume features
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        copy => { current => 1 },
    };

    my $key = 'current';
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
