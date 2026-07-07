---
name: BeEF hookpages extension
description: Architecture notes for the custom Hook Page Generator extension added to BeEF.
---

## What it is
`extensions/hookpages/` — a BeEF extension that dynamically creates and serves lure/honeypot pages
that inject `hook.js` into visitors' browsers. Pages are persisted in BeEF's SQLite DB.

## Key files
- `extension.rb` — module definition, AR CRUD helpers, template renderers, mounts handlers
- `handler.rb` — Sinatra router: `GET /hookpages` (manager UI), `GET /hookpages/:slug` (live page)
- `rest/hookpages_rest.rb` — REST API: GET/POST/PUT/DELETE `/api/hookpages/` (requires `?token=`)
- `html/manager.html` — dark-themed UI with miner toggle; stores API token in localStorage
- `config.yaml` — extension config including miner settings (wallet, coin, ws_proxy, threads)

## AR model
`core/main/models/hook_page.rb` — `BeEF::Core::Models::HookPage`
Required by `core/core.rb` (added after `legacybrowseruseragents`).
Migration: `core/main/ar-migrations/026_create_hook_pages.rb`.

## Browser miner
`public/miner/miner.js` — loaded by hook pages when `miner_enabled: true`.
Runs a hidden Web Worker that connects to the local stratum-ws proxy (`miner-proxy/proxy.js`)
which forwards to `rx.unmineable.com:3333`. Mines XMR, unmineable converts to chosen coin (SOL).
Wallet address set in `extensions/hookpages/config.yaml` → `beef.extension.hookpages.miner.wallet`.

## BeEF command module
`modules/misc/crypto_miner/` — injects the miner into already-hooked browsers via the admin UI.

## Deployment
`deploy.sh` — full server setup (Ubuntu/Debian): Ruby via rbenv, Node, nginx, Let's Encrypt, UFW.
Credentials written to `/root/.beef_deploy_credentials` (chmod 600) — never echoed to console.

**Why credentials file:** Printing passwords to stdout leaks them to terminal logs, CI output, and shell history.
