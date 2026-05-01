// Package vpn wraps the Android VpnService lifecycle.
// It manages the TUN interface setup, per-app routing,
// and foreground service notification requirements for Android 14+.
package vpn

import (
	"context"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"

	vpnlog "github.com/smokyw/firefly21/core/log"
)

// ServiceConfig holds the parameters for establishing a VPN TUN interface.
type ServiceConfig struct {
	// TunnelAddr is the SOCKS5 address of hev-socks5-tunnel (e.g. "127.0.0.1:12345").
	TunnelAddr string

	// AllowedApps is the list of package names to route through the VPN (include mode).
	AllowedApps []string

	// DisallowedApps is the list of package names to exclude from VPN (exclude mode).
	DisallowedApps []string

	// AppMode controls per-app routing: "include" or "exclude".
	AppMode string

	Logger *vpnlog.Logger
}

// TUNDevice represents an active TUN interface.
type TUNDevice struct {
	fd     int
	name   string
	mu     sync.Mutex
	closed bool
}

// FD returns the file descriptor of the TUN device.
func (t *TUNDevice) FD() int {
	return t.fd
}

// Name returns the interface name (e.g. "tun0").
func (t *TUNDevice) Name() string {
	return t.name
}

// Close shuts down the TUN device and releases the file descriptor.
func (t *TUNDevice) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.closed {
		return nil
	}
	t.closed = true
	return syscall.Close(t.fd)
}

// tunState tracks the current TUN interface state globally.
var (
	activeTUN   *TUNDevice
	activeTUNMu sync.Mutex
)

// EstablishTUN creates and configures the VPN TUN interface.
//
// On Android, the actual TUN fd is obtained from VpnService.Builder via JNI.
// This function receives the fd from the Flutter/Android side through the
// VPN_TUN_FD environment variable or the IPC channel.
//
// The function blocks until ctx is cancelled, at which point it tears down the TUN.
func EstablishTUN(ctx context.Context, cfg ServiceConfig) error {
	if cfg.Logger != nil {
		cfg.Logger.Info("vpn", "establishing TUN interface", map[string]interface{}{
			"tunnel_addr": cfg.TunnelAddr,
			"app_mode":    cfg.AppMode,
		})
	}

	// Validate tunnel address.
	host, portStr, err := net.SplitHostPort(cfg.TunnelAddr)
	if err != nil {
		return fmt.Errorf("invalid tunnel address %q: %w", cfg.TunnelAddr, err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("invalid tunnel port %q", portStr)
	}
	_ = host

	// On Android the TUN fd is provided by the VpnService.Builder via JNI.
	// The Flutter host passes it through the VPN_TUN_FD env var or IPC.
	tunFD, err := obtainTUNFD(ctx, cfg)
	if err != nil {
		return fmt.Errorf("obtain TUN fd: %w", err)
	}

	dev := &TUNDevice{
		fd:   tunFD,
		name: "tun0",
	}

	activeTUNMu.Lock()
	activeTUN = dev
	activeTUNMu.Unlock()

	if cfg.Logger != nil {
		cfg.Logger.Info("vpn", "TUN interface established", map[string]interface{}{
			"fd":   tunFD,
			"name": dev.name,
		})
	}

	// Monitor lifecycle — when context is cancelled, tear down.
	go func() {
		<-ctx.Done()
		if cfg.Logger != nil {
			cfg.Logger.Info("vpn", "tearing down TUN interface", nil)
		}
		dev.Close()

		activeTUNMu.Lock()
		activeTUN = nil
		activeTUNMu.Unlock()
	}()

	return nil
}

// obtainTUNFD gets the TUN file descriptor from the Android VpnService.
// On Android this is received via JNI from VpnService.Builder.establish().
// For development/testing, it falls back to VPN_TUN_FD env var.
func obtainTUNFD(ctx context.Context, cfg ServiceConfig) (int, error) {
	// Check for pre-established fd from the Android host.
	if fdStr := os.Getenv("VPN_TUN_FD"); fdStr != "" {
		fd, err := strconv.Atoi(fdStr)
		if err != nil {
			return 0, fmt.Errorf("invalid VPN_TUN_FD %q: %w", fdStr, err)
		}
		return fd, nil
	}

	// On Android, the VpnService.Builder is called from the Kotlin/Java side.
	// This Go code receives the fd through the Android binding layer.
	// The builder configures:
	//   - addAddress("10.0.0.2", 32) for IPv4
	//   - addAddress("fd00::2", 128) for IPv6
	//   - addRoute("0.0.0.0", 0) to capture all IPv4 traffic
	//   - addRoute("::", 0) to capture all IPv6 traffic
	//   - addDnsServer(tunnelDNS) — forwarded through xray DoH
	//   - setMtu(1500)
	//   - Per-app routing via addAllowedApplication / addDisallowedApplication

	return 0, fmt.Errorf("TUN fd not available: set VPN_TUN_FD or run on Android")
}

// GetActiveTUN returns the currently active TUN device, if any.
func GetActiveTUN() *TUNDevice {
	activeTUNMu.Lock()
	defer activeTUNMu.Unlock()
	return activeTUN
}

// BuildVpnServiceConfig generates the VpnService.Builder configuration
// parameters to be passed to the Android side via IPC.
func BuildVpnServiceConfig(cfg ServiceConfig) map[string]interface{} {
	result := map[string]interface{}{
		"mtu":          1500,
		"ipv4_address": "10.0.0.2",
		"ipv4_prefix":  32,
		"ipv6_address": "fd00::2",
		"ipv6_prefix":  128,
		"ipv4_route":   "0.0.0.0/0",
		"ipv6_route":   "::/0",
		"tunnel_addr":  cfg.TunnelAddr,
	}

	switch strings.ToLower(cfg.AppMode) {
	case "include":
		result["allowed_apps"] = cfg.AllowedApps
	case "exclude":
		result["disallowed_apps"] = cfg.DisallowedApps
	default:
		// No per-app routing — all traffic goes through VPN.
	}

	return result
}
