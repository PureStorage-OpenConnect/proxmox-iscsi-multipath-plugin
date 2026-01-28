/*
 * iSCSI Multipath Storage Plugin GUI for Proxmox VE
 * This file is appended to pvemanagerlib.js by install-gui.sh
 */

// Register iSCSI Multipath in the storage schema (for Add menu and type display)
PVE.Utils.storageSchema.iscsimpath = {
    name: 'iSCSI Multipath',
    ipanel: 'ISCSIMultipathInputPanel',
    faIcon: 'database',
    backups: false,
};

// Input panel for iSCSI Multipath storage configuration
Ext.define('PVE.storage.ISCSIMultipathInputPanel', {
    extend: 'PVE.panel.StorageBase',
    mixins: ['Proxmox.Mixin.CBind'],

    onGetValues: function(values) {
        let me = this;

        // Remove empty optional fields so they don't get sent to the API
        let optionalFields = [
            'iscsi_host_iface', 'iscsi_username', 'iscsi_password',
            'iscsi_port', 'iscsi_startup', 'mpath_policy',
            'mpath_selector', 'mpath_no_path_retry'
        ];

        optionalFields.forEach(function(field) {
            if (!values[field] || values[field] === '') {
                delete values[field];
            }
        });

        // Remove 'delete' property if present - not supported by our plugin schema
        if (values['delete']) {
            delete values['delete'];
        }

        return me.callParent([values]);
    },

    column1: [
        {
            xtype: 'pmxDisplayEditField',
            cbind: {
                editable: '{isCreate}',
            },
            name: 'iscsi_portal',
            fieldLabel: gettext('Portal(s)'),
            emptyText: '192.168.1.100,192.168.1.101',
            allowBlank: false,
        },
        {
            xtype: 'proxmoxintegerfield',
            name: 'iscsi_port',
            fieldLabel: gettext('Port'),
            value: 3260,
            minValue: 1,
            maxValue: 65535,
            allowBlank: true,
        },
        {
            xtype: 'fieldcontainer',
            fieldLabel: gettext('Target IQN(s)'),
            layout: 'hbox',
            items: [
                {
                    xtype: 'tagfield',
                    name: 'iscsi_target',
                    reference: 'targetField',
                    flex: 1,
                    editable: true,
                    queryMode: 'local',
                    displayField: 'iqn',
                    valueField: 'iqn',
                    createNewOnEnter: true,
                    createNewOnBlur: true,
                    filterPickList: true,
                    emptyText: gettext('Discover or enter target IQN(s)'),
                    allowBlank: true,
                    store: {
                        fields: ['iqn'],
                        data: [],
                    },
                    cbind: {
                        disabled: '{!isCreate}',
                    },
                    // Convert array to comma-separated string for submission
                    getSubmitValue: function() {
                        let val = this.getValue();
                        if (Ext.isArray(val)) {
                            return val.join(',');
                        }
                        return val;
                    },
                },
                {
                    xtype: 'button',
                    text: gettext('Discover'),
                    margin: '0 0 0 5',
                    cbind: {
                        disabled: '{!isCreate}',
                    },
                    handler: function(btn) {
                        let panel = btn.up('inputpanel');
                        let win = btn.up('window');
                        let targetField = panel.down('[name=iscsi_target]');

                        // Get portal value - use window's getValues for proper handling
                        let portal = '';
                        let port = 3260;

                        if (win && win.down('form')) {
                            let formPanel = win.down('form');
                            let formValues = formPanel.getForm().getFieldValues();
                            portal = formValues.iscsi_portal || '';
                            port = formValues.iscsi_port || 3260;
                        }

                        // Fallback: try to find the field directly
                        if (!portal) {
                            let portalComp = panel.down('[name=iscsi_portal]');
                            if (portalComp) {
                                // pmxDisplayEditField wraps the actual input
                                if (portalComp.getSubmitValue) {
                                    portal = portalComp.getSubmitValue();
                                } else if (portalComp.getValue) {
                                    portal = portalComp.getValue();
                                }
                            }
                        }

                        if (!portal) {
                            Ext.Msg.alert(gettext('Error'), gettext('Please enter portal address first'));
                            return;
                        }

                        let portField = panel.down('[name=iscsi_port]');
                        if (!port && portField) {
                            port = portField.getValue() || 3260;
                        }

                        btn.setDisabled(true);
                        btn.setText(gettext('Discovering...'));

                        // Split portals and query each one
                        let portals = portal.split(',').map(p => p.trim()).filter(p => p);

                        if (portals.length === 0) {
                            btn.setDisabled(false);
                            btn.setText(gettext('Discover'));
                            Ext.Msg.alert(gettext('Error'), gettext('No valid portals specified'));
                            return;
                        }

                        // Track results per portal
                        let portalResults = {};
                        let completed = 0;
                        let errors = [];

                        // Function to process results after all portals queried
                        let processResults = function() {
                            btn.setDisabled(false);
                            btn.setText(gettext('Discover'));

                            if (errors.length === portals.length) {
                                Ext.Msg.alert(gettext('Error'), gettext('Discovery failed on all portals'));
                                return;
                            }

                            // Find intersection - targets that appear on ALL successful portals
                            let successfulPortals = Object.keys(portalResults);
                            if (successfulPortals.length === 0) {
                                Ext.Msg.alert(gettext('Discovery'), gettext('No targets found'));
                                return;
                            }

                            // Start with targets from first portal
                            let commonTargets = [...portalResults[successfulPortals[0]]];

                            // Intersect with each subsequent portal
                            for (let i = 1; i < successfulPortals.length; i++) {
                                let portalTargets = portalResults[successfulPortals[i]];
                                commonTargets = commonTargets.filter(t => portalTargets.includes(t));
                            }

                            if (commonTargets.length === 0) {
                                let msg = gettext('No targets found on all portals.');
                                if (errors.length > 0) {
                                    msg += ' ' + errors.length + ' portal(s) failed.';
                                }
                                Ext.Msg.alert(gettext('Discovery'), msg);
                                return;
                            }

                            let targets = commonTargets.map(iqn => ({ iqn: iqn }));
                            targetField.getStore().loadData(targets);

                            if (targets.length === 1) {
                                targetField.setValue([targets[0].iqn]);
                            } else {
                                targetField.expand();
                                Ext.Msg.show({
                                    title: gettext('Targets Found'),
                                    message: Ext.String.format(
                                        gettext('{0} target(s) available on all {1} portal(s)'),
                                        targets.length, successfulPortals.length
                                    ),
                                    buttons: Ext.Msg.OK,
                                    icon: Ext.Msg.INFO,
                                });
                            }
                        };

                        // Query each portal
                        portals.forEach(function(p) {
                            let portalAddr = p;
                            if (port && port !== 3260) {
                                portalAddr = p + ':' + port;
                            }

                            Proxmox.Utils.API2Request({
                                url: '/nodes/' + Proxmox.NodeName + '/scan/iscsi',
                                method: 'GET',
                                params: { portal: portalAddr },
                                success: function(response) {
                                    let data = response.result.data || [];
                                    let iqns = data.map(item => item.target).filter(t => t);
                                    portalResults[p] = iqns;
                                    completed++;
                                    if (completed === portals.length) {
                                        processResults();
                                    }
                                },
                                failure: function(response) {
                                    errors.push(p + ': ' + response.htmlStatus);
                                    completed++;
                                    if (completed === portals.length) {
                                        processResults();
                                    }
                                },
                            });
                        });
                    },
                },
            ],
        },
    ],

    column2: [
        {
            xtype: 'proxmoxcheckbox',
            name: 'shared',
            checked: true,
            uncheckedValue: 0,
            fieldLabel: gettext('Shared'),
        },
        {
            xtype: 'proxmoxKVComboBox',
            name: 'iscsi_startup',
            fieldLabel: gettext('Startup'),
            value: 'automatic',
            comboItems: [
                ['automatic', 'Automatic'],
                ['manual', 'Manual'],
                ['onboot', 'On Boot'],
            ],
            allowBlank: true,
        },
        {
            xtype: 'textfield',
            name: 'iscsi_host_iface',
            fieldLabel: gettext('Host Interface(s)'),
            emptyText: 'eth0,eth1',
            allowBlank: true,
            submitEmptyText: false,
            tooltip: 'Bind iSCSI sessions to specific network interfaces for multipath. Comma-separated list of interface names.',
        },
        {
            xtype: 'proxmoxKVComboBox',
            name: 'mpath_policy',
            fieldLabel: gettext('Path Policy'),
            value: '',
            comboItems: [
                ['', 'Auto (System Default)'],
                ['failover', 'Failover (Active/Passive)'],
                ['multibus', 'Multibus (Active/Active)'],
                ['group_by_prio', 'Group by Priority'],
                ['group_by_node_name', 'Group by Node Name'],
            ],
            allowBlank: true,
        },
        {
            xtype: 'proxmoxKVComboBox',
            name: 'mpath_selector',
            fieldLabel: gettext('Path Selector'),
            value: '',
            comboItems: [
                ['', 'Auto (System Default)'],
                ['round-robin', 'Round Robin'],
                ['queue-length', 'Queue Length'],
                ['service-time', 'Service Time'],
            ],
            allowBlank: true,
        },
        {
            xtype: 'proxmoxKVComboBox',
            name: 'mpath_no_path_retry',
            fieldLabel: gettext('No Path Retry'),
            value: '',
            comboItems: [
                ['', 'Auto (System Default)'],
                ['fail', 'Fail Immediately'],
                ['queue', 'Queue Forever'],
                ['5', '5 Retries'],
                ['10', '10 Retries'],
                ['30', '30 Retries'],
            ],
            allowBlank: true,
        },
        {
            xtype: 'proxmoxcheckbox',
            name: 'auto_lvm',
            fieldLabel: gettext('Auto LVM'),
            boxLabel: gettext('Create PV/VG on empty devices'),
            uncheckedValue: 0,
            value: 0,
        },
    ],

    columnB: [
        {
            xtype: 'textfield',
            name: 'iscsi_username',
            fieldLabel: gettext('CHAP Username'),
            allowBlank: true,
            submitEmptyText: false,
        },
        {
            xtype: 'textfield',
            name: 'iscsi_password',
            fieldLabel: gettext('CHAP Password'),
            inputType: 'password',
            allowBlank: true,
            submitEmptyText: false,
        },
    ],
});

