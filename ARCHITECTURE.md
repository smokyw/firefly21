# Architecture

## System Overview

```
┌─────────────────┐     ┌─────────────────────────────┐
│   Flutter UI    │◄───►│   Network Service (Go)      │
│   (main thread) │ IPC │   - hev-socks5-tunnel       │
└─────────────────┘     │   - Arti (subprocess)       │
                        │   - xray-core (embedded)    │
                        │   - VpnService wrapper      │
                        └─────────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │   Android VpnService    │
                    │   (Foreground, specialUse)│
                    └─────────────────────────┘
```

## Traffic Flow

### Normal Mode (with TOR)
```
TUN Interface (VpnService)
  │ Raw IP packets
  ▼
hev-socks5-tunnel
  │ SOCKS5 on random port (10000-60000)
  ▼
Arti (TOR client)
  │ SOCKS5 on random port (10000-60000)
  │ Traffic routed through TOR circuits
  ▼
xray-core
  │ Any protocol: VLESS/VMess/Trojan/SS/WG/...
  │ DNS: DoH resolver (no port 53)
  ▼
Internet (target server)
```

### Direct Mode (skip_arti: true)
```
TUN Interface
  │
  ▼
hev-socks5-tunnel
  │ SOCKS5
  ▼
xray-core
  │ Protocol from config
  ▼
Internet
```

## IPC Protocol

**Transport:** Unix Domain Socket (AF_UNIX)
**Path:** `${filesDir}/vpn_${random_128bit_hex}.sock`
**Format:** JSON-RPC 2.0

### Methods

| Method | Description |
|--------|-------------|
| `connect` | Start VPN with config URL and per-app routing params |
| `disconnect` | Stop all VPN components |
| `status` | Get current connection state and traffic stats |
| `get_logs` | Retrieve recent log entries from ring buffer |

### Security

- Socket path randomized (128-bit entropy) on each start
- `chmod 0600` on socket file
- UID verification via `SO_PEERCRED` on every connection

## Component Lifecycle

### Startup Sequence

1. Flutter UI sends `connect` via Platform Channel
2. Android `VpnTorService` starts as foreground service
3. Go core starts: IPC server → xray-core → Arti → hev-socks5-tunnel
4. VpnService.Builder establishes TUN interface
5. TUN fd passed to hev-socks5-tunnel
6. Status reported back to Flutter UI

### Shutdown Sequence

1. User taps Disconnect (or notification action)
2. Go `cancel.Manager.Cancel("connection")` cancels all child contexts
3. Each component's goroutine detects cancellation and cleans up:
   - hev-socks5-tunnel: process killed, config file removed
   - Arti: subprocess killed, data cleaned
   - xray-core: instance stopped
   - TUN: file descriptor closed
4. VpnService stops foreground, removes notification

## Cancellation Model

```go
cancel.Manager
  └─ rootCtx (background)
       ├─ "ipc" context (IPC server lifetime)
       └─ "connection" context (VPN connection lifetime)
            // Cancelling "connection" stops xray, arti, hev, TUN
            // Without affecting the IPC server
```

## Logging Architecture

```
Go Core                  Flutter UI
┌─────────────┐         ┌─────────────┐
│ Logger      │         │ LogsTab     │
│ - Ring buf  │──IPC───►│ - Virtual   │
│ - File I/O  │         │   list      │
│ - Redaction │         │ - Filters   │
│ - Rotation  │         │ - Export    │
└─────────────┘         └─────────────┘
```

**Entry format:**
```json
{
  "timestamp": "2026-05-01T12:34:56.789Z",
  "level": "info",
  "source": "xray",
  "message": "Connected to server example.com:443",
  "context": { "protocol": "vless" }
}
```

**Sources:** `xray`, `arti`, `hev`, `vpn`, `ipc`, `main`
**Levels:** `trace`, `debug`, `info`, `warn`, `error`

## Extensibility

### PTProvider Interface
```go
type PTProvider interface {
    Start(ctx context.Context, config PTConfig) error
    GetSOCKSAddr() (string, error)
    Stop() error
    IsReady() bool
}
// Implementations: XrayPTProvider, MockPTProvider
```

### SocksProvider Interface
```go
type SocksProvider interface {
    StartFromTUN(tunFD int) error
    GetListenAddr() string
    Stop()
}
// Implementations: HevSocksProvider
```

## DNS Resolution

1. All DNS queries captured by hev-socks5-tunnel's mapdns
2. Forwarded to xray-core's DoH resolver
3. DoH endpoint from config (`doh_server`)
4. Optional `doh_server_ip` for direct connection (bypasses DNS blocking of the DoH hostname)
5. **No port 53 listener** in the application

## Android 14+ Compliance

- `foregroundServiceType="specialUse"` in manifest
- `PROPERTY_SPECIAL_USE_FGS_SUBTYPE="vpn"` property on the service
- `FOREGROUND_SERVICE_SPECIAL_USE` permission declared
- Ongoing notification with disconnect action
- VPN consent dialog via `VpnService.prepare()`
