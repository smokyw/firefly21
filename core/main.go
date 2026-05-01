// Package main is the entry point for the VPN+TOR core service.
// It initializes all subsystems (xray-core, Arti, hev-socks5-tunnel),
// sets up IPC for communication with the Flutter UI, and manages
// the overall service lifecycle with graceful shutdown.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/smokyw/firefly21/core/cancel"
	"github.com/smokyw/firefly21/core/config"
	"github.com/smokyw/firefly21/core/ipc"
	vpnlog "github.com/smokyw/firefly21/core/log"
	"github.com/smokyw/firefly21/core/tor"
	"github.com/smokyw/firefly21/core/tunnel"
	"github.com/smokyw/firefly21/core/vpn"
	"github.com/smokyw/firefly21/core/xray"
)

func main() {
	// Initialize the structured logger first so every component can use it.
	logger := vpnlog.NewLogger(vpnlog.Config{
		Level:      vpnlog.LevelDebug,
		MaxSizeMB:  10,
		MaxFiles:   5,
		OutputDir:  filesDir(),
		JSONFormat: true,
	})
	defer logger.Close()

	logger.Info("main", "VPN+TOR core starting", nil)

	// Centralized cancellation for all subsystems.
	cm := cancel.NewManager()
	defer cm.CancelAll()

	// Trap OS signals for graceful shutdown.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		logger.Info("main", fmt.Sprintf("received signal %s, shutting down", sig), nil)
		cm.CancelAll()
	}()

	// IPC server — accepts commands from the Flutter UI over a Unix socket.
	ipcServer := ipc.NewServer(ipc.ServerConfig{
		FilesDir: filesDir(),
		Logger:   logger,
	})

	// Register RPC handlers for the Flutter UI.
	registerHandlers(ipcServer, cm, logger)

	// Start the IPC server in the background.
	ipcCtx := cm.NewContext("ipc")
	if err := ipcServer.Start(ipcCtx); err != nil {
		logger.Error("main", "failed to start IPC server", map[string]interface{}{"error": err.Error()})
		os.Exit(1)
	}
	logger.Info("main", fmt.Sprintf("IPC server listening on %s", ipcServer.SocketPath()), nil)

	// Block until cancellation.
	<-cm.RootContext().Done()
	logger.Info("main", "VPN+TOR core stopped", nil)
}

// registerHandlers wires up the JSON-RPC methods exposed to the Flutter UI.
func registerHandlers(srv *ipc.Server, cm *cancel.Manager, logger *vpnlog.Logger) {
	// connect — starts the full VPN pipeline.
	srv.Handle("connect", func(ctx context.Context, params map[string]interface{}) (interface{}, error) {
		configURL, _ := params["config_url"].(string)
		if configURL == "" {
			configURL = "https://incss.ru/vless.conf"
		}

		// Parse the remote configuration.
		cfg, err := config.FetchAndParse(ctx, configURL)
		if err != nil {
			return nil, fmt.Errorf("config: %w", err)
		}

		// Per-app routing list (package names).
		allowedApps, _ := params["allowed_apps"].([]interface{})
		disallowedApps, _ := params["disallowed_apps"].([]interface{})
		appMode, _ := params["app_mode"].(string) // "include" or "exclude"

		connCtx := cm.NewContext("connection")

		// 1. Start xray-core with the parsed outbounds + DoH resolver.
		xrayInst, err := xray.Start(connCtx, xray.Config{
			Outbounds:    cfg.Outbounds,
			DOHServer:    cfg.DOHServer,
			DOHServerIP:  cfg.DOHServerIP,
			Logger:       logger,
		})
		if err != nil {
			cm.Cancel("connection")
			return nil, fmt.Errorf("xray: %w", err)
		}

		var socksChainAddr string

		if !cfg.SkipArti {
			// 2. Start Arti (TOR) subprocess with xray as upstream SOCKS proxy.
			artiInst, err := tor.Start(connCtx, tor.Config{
				UpstreamSOCKS: xrayInst.SOCKSAddr(),
				BridgeRSAID:   cfg.BridgeRSAID,
				BridgeEd25519: cfg.BridgeEd25519ID,
				FilesDir:      filesDir(),
				Logger:        logger,
			})
			if err != nil {
				cm.Cancel("connection")
				return nil, fmt.Errorf("arti: %w", err)
			}
			socksChainAddr = artiInst.SOCKSAddr()
		} else {
			// skip_arti mode — connect directly through xray.
			socksChainAddr = xrayInst.SOCKSAddr()
		}

		// 3. Start hev-socks5-tunnel to bridge TUN to the SOCKS chain.
		tunCfg := tunnel.Config{
			UpstreamSOCKS: socksChainAddr,
			FilesDir:      filesDir(),
			Logger:        logger,
		}
		hevInst, err := tunnel.Start(connCtx, tunCfg)
		if err != nil {
			cm.Cancel("connection")
			return nil, fmt.Errorf("hev-tunnel: %w", err)
		}

		// 4. Establish the Android VpnService TUN interface.
		vpnCfg := vpn.ServiceConfig{
			TunnelAddr:     hevInst.ListenAddr(),
			AllowedApps:    toStringSlice(allowedApps),
			DisallowedApps: toStringSlice(disallowedApps),
			AppMode:        appMode,
			Logger:         logger,
		}
		if err := vpn.EstablishTUN(connCtx, vpnCfg); err != nil {
			cm.Cancel("connection")
			return nil, fmt.Errorf("vpn: %w", err)
		}

		logger.Info("main", "VPN connected", map[string]interface{}{
			"skip_arti": cfg.SkipArti,
			"protocol":  cfg.Outbounds[0]["protocol"],
		})

		return map[string]interface{}{
			"status":    "connected",
			"skip_arti": cfg.SkipArti,
		}, nil
	})

	// disconnect — tears down all VPN components.
	srv.Handle("disconnect", func(ctx context.Context, params map[string]interface{}) (interface{}, error) {
		cm.Cancel("connection")
		logger.Info("main", "VPN disconnected by user", nil)
		return map[string]interface{}{"status": "disconnected"}, nil
	})

	// status — returns current connection state.
	srv.Handle("status", func(ctx context.Context, params map[string]interface{}) (interface{}, error) {
		return map[string]interface{}{
			"connected": cm.IsActive("connection"),
		}, nil
	})

	// get_logs — returns recent log entries.
	srv.Handle("get_logs", func(ctx context.Context, params map[string]interface{}) (interface{}, error) {
		limit := 100
		if l, ok := params["limit"].(float64); ok {
			limit = int(l)
		}
		entries := logger.RecentEntries(limit)
		return map[string]interface{}{"entries": entries}, nil
	})
}

// filesDir returns the application's private files directory.
// On Android this is set via environment variable by the Flutter host;
// falls back to /tmp for local development.
func filesDir() string {
	if d := os.Getenv("APP_FILES_DIR"); d != "" {
		return d
	}
	return "/tmp/vpntor"
}

// toStringSlice converts []interface{} (from JSON) to []string.
func toStringSlice(in []interface{}) []string {
	out := make([]string, 0, len(in))
	for _, v := range in {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}
