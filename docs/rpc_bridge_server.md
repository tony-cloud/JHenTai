# RPC Bridge Server

This project now includes a standalone JSON-RPC bridge:

- Script: `tool/rpc_bridge_server.dart`
- Endpoint: `POST /rpc`
- Transport: HTTP or HTTPS (optional TLS cert/key)

The bridge forwards selected RPC methods to EH/EX HTTP APIs and returns parser-compatible payloads (`headers` + `data`) for the Flutter client.

## Run

```bash
dart run tool/rpc_bridge_server.dart
```

## Environment Variables

- `JH_RPC_HOST`: bind host (default: `0.0.0.0`)
- `JH_RPC_PORT`: bind port (default: `3210`)
- `JH_RPC_TOKEN`: bearer token for RPC auth (optional, recommended)
- `JH_RPC_COOKIE`: raw EH/EX cookie header (optional, required for authenticated operations)
- `JH_RPC_TLS_CERT`: certificate file path (optional)
- `JH_RPC_TLS_KEY`: private key file path (optional)
- `JH_RPC_TLS_KEY_PASSWORD`: private key password (optional)

If both `JH_RPC_TLS_CERT` and `JH_RPC_TLS_KEY` are set, the server starts in HTTPS mode.

## Implemented Methods

- `system.health`
- `system.capabilities`
- `news.event`
- `gallery.page`
- `gallery.detail`
- `gallery.metadata`
- `gallery.metadatas`
- `gallery.imagePage`
- `system.reloadCertificates`
- `auth.setCookie`

## Runtime Certificate Reload

If TLS is enabled, call `system.reloadCertificates` to restart secure binding and reload certificate files from disk.

## Example JSON-RPC Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "system.health",
  "params": {}
}
```

## Notes

- In RPC mode, migrated Flutter methods now prefer RPC routing for core gallery/news flows.
- `flutter test` may fail in this repository because no `test` directory is present.
