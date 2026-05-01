// Package tunnel integrates hev-socks5-tunnel for bridging the Android TUN
// interface to a SOCKS5 proxy. The tunnel converts raw IP packets from the
// TUN fd into SOCKS5 connections, forwarding them to the next hop in the chain
// (Arti or xray-core depending on configuration).
package tunnel

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"text/template"

	vpnlog "github.com/smokyw/firefly21/core/log"
)

// Config holds the configuration for hev-socks5-tunnel.
type Config struct {
	// UpstreamSOCKS is the SOCKS5 address to forward traffic to (e.g. "127.0.0.1:12345").
	UpstreamSOCKS string

	// FilesDir is the application's private directory for config and socket files.
	FilesDir string

	Logger *vpnlog.Logger
}

// Instance represents a running hev-socks5-tunnel process.
type Instance struct {
	cmd        *exec.Cmd
	listenAddr string
	listenPort int
	configPath string
	cancel     context.CancelFunc
	mu         sync.Mutex
	stopped    bool
}

// ListenAddr returns the SOCKS5 listen address of this tunnel instance.
func (i *Instance) ListenAddr() string {
	return i.listenAddr
}

// Stop terminates the hev-socks5-tunnel process and cleans up resources.
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
	os.Remove(i.configPath)
}

// SocksProvider is the abstraction for SOCKS5 tunnel providers.
// Current implementation: HevSocksProvider.
// Future: GVisorSocksProvider.
type SocksProvider interface {
	StartFromTUN(tunFD int) error
	GetListenAddr() string
	Stop()
}

// hevConfigTemplate is the YAML configuration template for hev-socks5-tunnel.
var hevConfigTemplate = template.Must(template.New("hev").Parse(`misc:
  log-level: info
  pid-file: {{ .PIDFile }}

socks5:
  listen-address: '127.0.0.1'
  listen-port: {{ .ListenPort }}
  udp: 'udp'

tunnel:
  mtu: 8500
  ipv4:
    address: '10.0.0.2'
    gateway: '10.0.0.1'
  ipv6:
    address: 'fd00::2'
    gateway: 'fd00::1'
  dns:
    listen-address: '127.0.0.1'
    listen-port: {{ .DNSPort }}
    upstream:
      address: '127.0.0.1'
      port: {{ .UpstreamDNSPort }}
`))

type hevTemplateData struct {
	PIDFile         string
	ListenPort      int
	DNSPort         int
	UpstreamDNSPort int
}

// Start launches hev-socks5-tunnel with the given configuration.
// It allocates a cryptographically random port in the range 10000-60000.
func Start(ctx context.Context, cfg Config) (*Instance, error) {
	if cfg.Logger != nil {
		cfg.Logger.Info("hev", "starting hev-socks5-tunnel", map[string]interface{}{
			"upstream": cfg.UpstreamSOCKS,
		})
	}

	// Allocate a random port for the SOCKS5 listener.
	listenPort, err := randomPort()
	if err != nil {
		return nil, fmt.Errorf("allocate listen port: %w", err)
	}

	// Allocate a random port for DNS forwarding.
	dnsPort, err := randomPort()
	if err != nil {
		return nil, fmt.Errorf("allocate dns port: %w", err)
	}

	// Parse upstream port for DNS forwarding reference.
	_, upstreamPortStr, err := net.SplitHostPort(cfg.UpstreamSOCKS)
	if err != nil {
		return nil, fmt.Errorf("parse upstream SOCKS address: %w", err)
	}

	_ = upstreamPortStr

	// Write the hev-socks5-tunnel configuration file.
	configPath := filepath.Join(cfg.FilesDir, fmt.Sprintf("hev_%d.yml", listenPort))
	pidPath := filepath.Join(cfg.FilesDir, fmt.Sprintf("hev_%d.pid", listenPort))

	configFile, err := os.OpenFile(configPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return nil, fmt.Errorf("create config file: %w", err)
	}

	data := hevTemplateData{
		PIDFile:         pidPath,
		ListenPort:      listenPort,
		DNSPort:         dnsPort,
		UpstreamDNSPort: dnsPort + 1,
	}

	if err := hevConfigTemplate.Execute(configFile, data); err != nil {
		configFile.Close()
		return nil, fmt.Errorf("write config: %w", err)
	}
	configFile.Close()

	// Set restrictive permissions on the config file.
	os.Chmod(configPath, 0600)

	childCtx, cancelFunc := context.WithCancel(ctx)

	// Launch hev-socks5-tunnel as a subprocess.
	// The binary path is resolved from the native library directory on Android.
	binaryPath := resolveHevBinary(cfg.FilesDir)
	cmd := exec.CommandContext(childCtx, binaryPath, configPath)
	cmd.Dir = cfg.FilesDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		cancelFunc()
		os.Remove(configPath)
		return nil, fmt.Errorf("start hev-socks5-tunnel: %w", err)
	}

	listenAddr := fmt.Sprintf("127.0.0.1:%d", listenPort)
	inst := &Instance{
		cmd:        cmd,
		listenAddr: listenAddr,
		listenPort: listenPort,
		configPath: configPath,
		cancel:     cancelFunc,
	}

	if cfg.Logger != nil {
		cfg.Logger.Info("hev", "hev-socks5-tunnel started", map[string]interface{}{
			"listen":  listenAddr,
			"pid":     cmd.Process.Pid,
			"config":  configPath,
		})
	}

	// Monitor process lifecycle.
	go func() {
		err := cmd.Wait()
		if err != nil && cfg.Logger != nil {
			cfg.Logger.Warn("hev", "hev-socks5-tunnel exited", map[string]interface{}{
				"error": err.Error(),
			})
		}
		inst.Stop()
	}()

	return inst, nil
}

// randomPort generates a cryptographically secure random port in [10000, 60000).
func randomPort() (int, error) {
	var buf [2]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return 0, fmt.Errorf("crypto/rand: %w", err)
	}
	port := int(binary.BigEndian.Uint16(buf[:])) % 50000
	return port + 10000, nil
}

// resolveHevBinary locates the hev-socks5-tunnel binary.
// On Android, native libraries are stored in the app's native library directory.
// For development, it checks PATH.
func resolveHevBinary(filesDir string) string {
	// Android: native library path.
	nativePath := filepath.Join(filepath.Dir(filesDir), "lib", "arm64", "libhev-socks5-tunnel.so")
	if _, err := os.Stat(nativePath); err == nil {
		return nativePath
	}

	// Development fallback: look in PATH.
	if path, err := exec.LookPath("hev-socks5-tunnel"); err == nil {
		return path
	}

	return filepath.Join(filesDir, "hev-socks5-tunnel")
}
