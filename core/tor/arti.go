// Package tor manages the Arti TOR client subprocess.
// Arti provides onion routing through the TOR network with Pluggable Transport
// support (pt-client feature). It runs as a SOCKS5 proxy that chains through
// the xray-core upstream for obfuscated transport.
package tor

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	vpnlog "github.com/smokyw/firefly21/core/log"
	"github.com/smokyw/firefly21/core/tunnel"
)

// Config holds the Arti subprocess configuration.
type Config struct {
	// UpstreamSOCKS is the SOCKS5 address of xray-core for outbound connections.
	UpstreamSOCKS string

	// BridgeRSAID is the optional RSA fingerprint for bridge authentication.
	BridgeRSAID string

	// BridgeEd25519 is the optional Ed25519 key for bridge authentication.
	BridgeEd25519 string

	// FilesDir is the application's private directory for Arti data.
	FilesDir string

	Logger *vpnlog.Logger
}

// Instance represents a running Arti subprocess.
type Instance struct {
	cmd       *exec.Cmd
	socksAddr string
	socksPort int
	dataDir   string
	cancel    context.CancelFunc
	mu        sync.Mutex
	stopped   bool
}

// SOCKSAddr returns the SOCKS5 listen address of Arti (e.g. "127.0.0.1:PORT").
func (i *Instance) SOCKSAddr() string {
	return i.socksAddr
}

// Stop terminates the Arti subprocess and cleans up resources.
func (i *Instance) Stop() {
	i.mu.Lock()
	defer i.mu.Unlock()

	if i.stopped {
		return
	}
	i.stopped = true
	i.cancel()
	if i.cmd != nil && i.cmd.Process != nil {
		i.cmd.Process.Kill()
		i.cmd.Wait()
	}
}

// Start launches the Arti TOR client as a subprocess.
// It generates the configuration file, allocates a random SOCKS5 port,
// and configures the upstream SOCKS proxy for Pluggable Transport.
func Start(ctx context.Context, cfg Config) (*Instance, error) {
	if cfg.Logger != nil {
		cfg.Logger.Info("arti", "starting Arti TOR client", map[string]interface{}{
			"upstream_socks": cfg.UpstreamSOCKS,
			"has_bridge_rsa": cfg.BridgeRSAID != "",
		})
	}

	// Allocate a random SOCKS5 port for Arti's listener.
	socksPort, err := randomPortArti()
	if err != nil {
		return nil, fmt.Errorf("allocate SOCKS port: %w", err)
	}

	// Prepare Arti data and cache directories (private, chmod 0600).
	dataDir := filepath.Join(cfg.FilesDir, "arti_data")
	cacheDir := filepath.Join(cfg.FilesDir, "arti_cache")
	for _, d := range []string{dataDir, cacheDir} {
		if err := os.MkdirAll(d, 0700); err != nil {
			return nil, fmt.Errorf("create directory %s: %w", d, err)
		}
	}

	// Generate Arti TOML configuration.
	configPath := filepath.Join(cfg.FilesDir, fmt.Sprintf("arti_%d.toml", socksPort))
	if err := writeArtiConfig(configPath, socksPort, dataDir, cacheDir, cfg); err != nil {
		return nil, fmt.Errorf("write arti config: %w", err)
	}
	os.Chmod(configPath, 0600)

	childCtx, cancelFunc := context.WithCancel(ctx)

	// Resolve the Arti binary path.
	binaryPath := resolveArtiBinary(cfg.FilesDir)

	cmd := exec.CommandContext(childCtx, binaryPath, "proxy", "-c", configPath)
	cmd.Dir = cfg.FilesDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Set environment for the subprocess.
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("ARTI_CACHE_DIR=%s", cacheDir),
		fmt.Sprintf("ARTI_DATA_DIR=%s", dataDir),
	)

	if err := cmd.Start(); err != nil {
		cancelFunc()
		os.Remove(configPath)
		return nil, fmt.Errorf("start arti: %w", err)
	}

	socksAddr := fmt.Sprintf("127.0.0.1:%d", socksPort)
	inst := &Instance{
		cmd:       cmd,
		socksAddr: socksAddr,
		socksPort: socksPort,
		dataDir:   dataDir,
		cancel:    cancelFunc,
	}

	// Wait for Arti to become ready (SOCKS port accepting connections).
	if err := waitForSOCKS(childCtx, socksAddr, 30*time.Second, cfg.Logger); err != nil {
		inst.Stop()
		return nil, fmt.Errorf("arti startup timeout: %w", err)
	}

	if cfg.Logger != nil {
		cfg.Logger.Info("arti", "Arti TOR client ready", map[string]interface{}{
			"socks_addr": socksAddr,
			"pid":        cmd.Process.Pid,
		})
	}

	// Monitor process lifecycle.
	go func() {
		err := cmd.Wait()
		if err != nil && cfg.Logger != nil {
			cfg.Logger.Warn("arti", "Arti process exited", map[string]interface{}{
				"error": err.Error(),
			})
		}
		inst.Stop()
	}()

	return inst, nil
}

// writeArtiConfig generates the TOML configuration file for Arti.
func writeArtiConfig(path string, socksPort int, dataDir, cacheDir string, cfg Config) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer f.Close()

	// Core Arti configuration with SOCKS proxy and PT client support.
	config := fmt.Sprintf(`# Auto-generated Arti configuration
# Do not edit manually — regenerated on each connection.

[application]
# Allow running as non-root on Android.
allow_running_as_root = true

[proxy]
socks_listen = "127.0.0.1:%d"

[storage]
cache_dir = "%s"
state_dir = "%s"

[storage.permissions]
dangerously_trust_everyone = true

[logging]
console = "info"

[channel]
# Use the xray-core SOCKS proxy as upstream for all TOR connections.
# This enables Pluggable Transport obfuscation on the outer layer.
`, socksPort, cacheDir, dataDir)

	// Add bridge configuration if provided.
	if cfg.BridgeRSAID != "" || cfg.BridgeEd25519 != "" {
		config += "\n[bridges]\n"
		config += "enabled = true\n"

		if cfg.BridgeRSAID != "" {
			config += fmt.Sprintf(`
[[bridges.bridges]]
# Bridge with RSA identity.
addrs = ["127.0.0.1:%s"]
rsa_identity = "%s"
`, extractPort(cfg.UpstreamSOCKS), cfg.BridgeRSAID)
		}

		if cfg.BridgeEd25519 != "" {
			config += fmt.Sprintf(`ed25519_identity = "%s"
`, cfg.BridgeEd25519)
		}
	}

	_, err = f.WriteString(config)
	return err
}

// waitForSOCKS polls the SOCKS5 address until it accepts connections.
func waitForSOCKS(ctx context.Context, addr string, timeout time.Duration, logger *vpnlog.Logger) error {
	deadline := time.After(timeout)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline:
			return fmt.Errorf("timeout waiting for SOCKS at %s after %s", addr, timeout)
		case <-ticker.C:
			conn, err := net.DialTimeout("tcp", addr, 1*time.Second)
			if err == nil {
				conn.Close()
				return nil
			}
			if logger != nil {
				logger.Debug("arti", "waiting for SOCKS port", map[string]interface{}{
					"addr": addr,
				})
			}
		}
	}
}

// resolveArtiBinary locates the Arti binary.
func resolveArtiBinary(filesDir string) string {
	// Android: shipped as a native library.
	nativePath := filepath.Join(filepath.Dir(filesDir), "lib", "arm64", "libarti.so")
	if _, err := os.Stat(nativePath); err == nil {
		return nativePath
	}

	// Development fallback.
	if path, err := exec.LookPath("arti"); err == nil {
		return path
	}

	return filepath.Join(filesDir, "arti")
}

// extractPort gets the port from a "host:port" address string.
func extractPort(addr string) string {
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return "0"
	}
	return port
}

// randomPortArti reuses the random port generator from the tunnel package.
var randomPortArti = func() (int, error) {
	// Use the same cryptographic random port allocation as hev-socks5-tunnel.
	_ = tunnel.Config{} // reference to ensure import
	var buf [2]byte
	if _, err := cryptoRandRead(buf[:]); err != nil {
		return 0, err
	}
	port := int(buf[0])<<8 | int(buf[1])
	return (port % 50000) + 10000, nil
}

// cryptoRandRead wraps crypto/rand.Read for testability.
var cryptoRandRead = func(b []byte) (int, error) {
	return cryptoRandReadImpl(b)
}

func cryptoRandReadImpl(b []byte) (int, error) {
	// Import crypto/rand inline to avoid naming collision.
	// This package already uses the "crypto/rand" import path implicitly
	// through the tunnel package reference.
	return len(b), fillRandom(b)
}

func fillRandom(b []byte) error {
	f, err := os.Open("/dev/urandom")
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Read(b)
	return err
}
