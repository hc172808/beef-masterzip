# BeEF — Browser Exploitation Framework

BeEF is a penetration testing tool focused on web browser security assessment. It allows security professionals to assess the security posture of a target environment using client-side attack vectors.

## Running

The app starts automatically via the configured workflow. To start manually:

```bash
bundle exec ruby beef
```

## Access

- **Web UI:** open the Replit preview (port 5000) then navigate to `/ui/panel`
- **Username:** `beef`
- **Password:** set in `config.yaml` under `beef.credentials.passwd`

## Configuration

Edit `config.yaml` to change:
- Credentials (`beef.credentials.user` / `beef.credentials.passwd`)
- HTTP port (`beef.http.port`) — currently set to `5000` for Replit compatibility
- Extensions (admin UI, proxy, network, etc.)

## Dependencies

- Ruby 3.2 (via Replit module)
- SQLite 3 (system dependency)
- Node.js 20 (system dependency)
- Ruby gems managed via Bundler (`bundle install`)

## Notes

- BeEF refuses to start with the default `beef`/`beef` credentials — always set a custom password.
- The database file (`beef.db`) is created automatically on first run.
- GeoIP is enabled in config but the MaxMind database is not installed; disable with `geoip.enable: false` if not needed.

## User Preferences

- Port changed from 3000 → 5000 to work with Replit's webview proxy.
