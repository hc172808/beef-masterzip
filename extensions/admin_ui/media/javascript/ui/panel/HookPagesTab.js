// ── Hook Pages Tab ────────────────────────────────────────────────────────────
// Embeds the Hook Page Manager (/hookpages) inside the BeEF admin panel.
// The manager UI handles its own API token via localStorage, so it works
// seamlessly here.

HookPagesTab = function() {
    HookPagesTab.superclass.constructor.call(this, {
        id: 'hookpages-tab',
        title: '🎣 Hook Pages',
        layout: 'fit',
        closable: false,
        border: false,
        items: [{
            xtype: 'panel',
            border: false,
            layout: 'fit',
            html: '<iframe id="hookpages-frame" src="/hookpages" ' +
                  'style="width:100%;height:100%;border:none;display:block;" ' +
                  'frameborder="0" allowtransparency="true"></iframe>'
        }],
        listeners: {
            activate: function(tab) {
                // Refresh the iframe so it picks up newly-created pages
                var frame = document.getElementById('hookpages-frame');
                if (frame && frame.contentWindow) {
                    try { frame.contentWindow.loadPages && frame.contentWindow.loadPages(); }
                    catch(e) {}
                }
            }
        }
    });
};

Ext.extend(HookPagesTab, Ext.Panel, {});
