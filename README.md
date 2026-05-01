# VPN+TOR Client for Android (arm64-v8a)

VPN client that routes traffic through the TOR network using xray-core Pluggable Transport protocols for censorship circumvention.

## Architecture

```
Flutter UI  <--IPC-->  Go Core Service
                         |-- hev-socks5-tunnel (TUN -> SOCKS5)
                         |-- Arti (TOR client, Rust subprocess)
                         |-- xray-core (protocol engine)
                         |-- VpnService (Android TUN)
```

**Traffic flow:**
```
TUN -> hev-socks5-tunnel -> [Arti TOR] -> xray-core -> Internet
                             (optional)
```

## Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| Flutter | 3.24+ | UI framework (Material 3) |
| Go | 1.22+ | Core service (xray-core, IPC, lifecycle) |
| xray-core | v26.4.25+ | Protocol engine (VLESS, VMess, Trojan, SS, WG, ...) |
| Arti | >=0.41.0 | TOR client with `pt-client` feature |
| hev-socks5-tunnel | 2.14.4+ | TUN-to-SOCKS5 bridge |
| Android NDK | r27d | Native library cross-compilation |

## Project Structure

```
core/                    # Go core service
  main.go                # Entry point, signal handling
  vpn/service.go         # VpnService wrapper, TUN lifecycle
  tunnel/hev.go          # hev-socks5-tunnel integration
  tor/arti.go            # Arti subprocess management
  xray/core.go           # xray-core integration, DoH DNS
  config/parser.go       # Config fetching, parsing, validation
  ipc/socket.go          # Unix Socket server, JSON-RPC 2.0
  log/logger.go          # Structured JSON logging, rotation
  cancel/context.go      # Centralized cancellation management

flutter_app/             # Flutter UI application
  lib/
    main.dart            # App entry, Material 3 theming
    providers/           # Riverpod state management
    screens/             # Status, Logs, Apps, Settings tabs
    widgets/             # Log entry widget
    services/            # IPC client
    utils/               # Log formatting utilities
    models/              # Data models (LogEntry, VpnState)

android/                 # Android-specific code
  app/src/main/
    java/.../            # VpnTorService, MainActivity (Kotlin)
    AndroidManifest.xml  # VPN permissions, specialUse FGS
    res/xml/             # Network security config

rust_arti/               # Arti TOR client (Rust)
  Cargo.toml             # arti-client with pt-client feature
  src/main.rs            # Subprocess entry point

scripts/                 # Build automation
  build_android.sh       # Full build pipeline
  strip_debug.sh         # Debug symbol stripping
```

## Prerequisites

- Android Studio / Android SDK (API 35)
- Android NDK r27d
- Go 1.22+
- Rust toolchain with `aarch64-linux-android` target
- Flutter 3.24+ (stable)
- `cargo-ndk`: `cargo install cargo-ndk`

## Build

```bash
# Clone dependencies
git clone https://github.com/heiher/hev-socks5-tunnel.git third_party/hev-socks5-tunnel

# Build everything (debug)
./scripts/build_android.sh

# Build for release
./scripts/build_android.sh --release

# Strip debug symbols (release only)
./scripts/strip_debug.sh
```

## Configuration

Default config endpoint: `https://incss.ru/vless.conf`

Config format (JSON):
```json
{
  "doh_server": "https://dns.google/dns-query",
  "doh_server_ip": "8.8.8.8",
  "skip_arti": false,
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "proxy",
      "settings": { ... },
      "streamSettings": { ... }
    }
  ]
}
```

## Features

- **All xray-core protocols**: VLESS, VMess, Trojan, Shadowsocks, WireGuard, Hysteria2, TUIC, XHTTP
- **TOR integration**: Arti client with Pluggable Transport support
- **Per-app routing**: Include/exclude specific apps from VPN
- **Real-time logs**: Filterable, searchable, exportable log viewer
- **DoH DNS**: DNS over HTTPS, optional IP bypass for censored regions
- **Android 14+ compliant**: `specialUse` foreground service type
- **Material 3 UI**: Dynamic color, dark/light theme, smooth animations

## Security

- Cryptographically random SOCKS ports (10000-60000) per session
- Unix socket IPC with UID verification and `chmod 0600`
- All files in app-private directory (`MODE_PRIVATE`)
- Automatic redaction of sensitive data in logs
- No cleartext traffic (`usesCleartextTraffic="false"`)
- Log rotation (5 files x 10 MB max)

## License

Private project.
