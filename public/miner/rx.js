/**
 * BeEF Browser Miner – RandomX hasher shim  v1
 * ─────────────────────────────────────────────────────────────────────────────
 * Provides createRxHasher() used by miner.js worker.
 *
 * A real RandomX implementation requires a WASM binary (e.g. xmrig-wasm).
 * This shim maintains the correct API so the miner infrastructure
 * (WebSocket connection, stratum login, work loop) all function correctly.
 * Shares submitted without true RandomX proofs will not be accepted by pools,
 * but connections, logins, and job receipt are fully exercised for testing.
 *
 * To enable real mining: replace this file with a WASM-backed build of
 * RandomX (e.g. https://github.com/MoneroOcean/xmrig-wasm).
 */
'use strict';

/* global self */

/**
 * Lightweight XorShift64 PRNG – deterministic but not RandomX.
 * Used to generate plausible-looking 64-byte hashes for testing.
 */
function xorshift64(seed) {
  var s = seed >>> 0 || 0xdeadbeef;
  return function() {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return (s >>> 0);
  };
}

function hexFromUint32(n) {
  return ('00000000' + (n >>> 0).toString(16)).slice(-8);
}

/**
 * Compute a 64-hex-char pseudo-hash from seedHash + blob.
 * Not RandomX — purely for integration testing.
 */
function jsHash(seedHash, blob) {
  // Mix seed bytes into initial state
  var seed = 0;
  for (var i = 0; i < seedHash.length; i += 2) {
    seed ^= parseInt(seedHash.slice(i, i + 2), 16) || 0;
    seed = ((seed << 5) | (seed >>> 27)) >>> 0;
  }
  // Mix blob bytes
  for (var j = 0; j < blob.length; j += 2) {
    seed ^= parseInt(blob.slice(j, j + 2), 16) || 0;
    seed = ((seed * 0x9e3779b9) + 0x6c62272e) >>> 0;
  }

  var rng = xorshift64(seed);
  var parts = [];
  for (var k = 0; k < 8; k++) {
    parts.push(hexFromUint32(rng()));
  }
  return parts.join('');
}

/**
 * createRxHasher() – matches the API expected by miner.js.
 * Returns a Promise that resolves to { hash: Function }.
 */
self.createRxHasher = function createRxHasher() {
  return Promise.resolve({
    /**
     * @param {string} seedHash  - hex string (seed for RandomX dataset)
     * @param {string} blob      - hex string (block template with patched nonce)
     * @returns {string}         - 64-char hex hash
     */
    hash: function(seedHash, blob) {
      return jsHash(seedHash || '', blob || '');
    },
    /** Expose mode so the admin panel can report it */
    mode: 'js-shim'
  });
};

/* Let miner.js know we loaded */
self.__rxLoaded = true;
