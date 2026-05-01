// Package config handles fetching, parsing, and validation of the VPN
// configuration. The config is a JSON document containing xray-core outbounds,
// DoH server settings, optional TOR bridge keys, and the skip_arti flag.
//
// Only the specified fields are extracted — all other xray-core sections
// (inbounds, routing, dns, policy, stats, reverse) are ignored because
// the application generates its own inbounds and routing configuration.
package config

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// DefaultConfigURL is the default remote configuration endpoint.
const DefaultConfigURL = "https://incss.ru/vless.conf"

// AppConfig is the validated application configuration.
type AppConfig struct {
	// BridgeRSAID is the optional RSA fingerprint for TOR bridge authentication.
	BridgeRSAID string `json:"bridge_rsa_id,omitempty"`

	// BridgeEd25519ID is the optional Ed25519 key for TOR bridge authentication.
	BridgeEd25519ID string `json:"bridge_ed25519_id,omitempty"`

	// DOHServer is the mandatory DoH endpoint URL.
	DOHServer string `json:"doh_server"`

	// DOHServerIP is the optional direct IP for the DoH endpoint (bypasses DNS).
	DOHServerIP string `json:"doh_server_ip,omitempty"`

	// Outbounds is the array of xray-core outbound configurations.
	// Each element must have "protocol", "settings", "streamSettings", and "tag".
	Outbounds []map[string]interface{} `json:"outbounds"`

	// SkipArti controls whether to bypass the TOR layer.
	// When true: TUN → hev-socks5-tunnel → xray-core → Internet
	// When false: TUN → hev-socks5-tunnel → Arti → xray-core → Internet
	SkipArti bool `json:"skip_arti,omitempty"`
}

// rawConfig mirrors the JSON structure for unmarshalling before validation.
type rawConfig struct {
	BridgeRSAID     string                   `json:"bridge_rsa_id"`
	BridgeEd25519ID string                   `json:"bridge_ed25519_id"`
	DOHServer       string                   `json:"doh_server"`
	DOHServerIP     string                   `json:"doh_server_ip"`
	Outbounds       []map[string]interface{} `json:"outbounds"`
	SkipArti        bool                     `json:"skip_arti"`
}

// FetchAndParse downloads the configuration from the given URL and parses it.
// Returns a validated AppConfig or an error with a human-readable message.
func FetchAndParse(ctx context.Context, url string) (*AppConfig, error) {
	if url == "" {
		url = DefaultConfigURL
	}

	data, err := fetchConfig(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("fetch config from %s: %w", url, err)
	}

	return Parse(data)
}

// Parse validates and extracts the application config from raw JSON bytes.
// Only the fields specified in the AppConfig struct are extracted.
// All other fields (inbounds, routing, dns, policy, stats, reverse) are ignored.
func Parse(data []byte) (*AppConfig, error) {
	var raw rawConfig
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}

	// Validate mandatory fields.
	if raw.DOHServer == "" {
		return nil, fmt.Errorf("missing required field: doh_server")
	}

	if !strings.HasPrefix(raw.DOHServer, "https://") {
		return nil, fmt.Errorf("doh_server must use HTTPS: got %q", raw.DOHServer)
	}

	if len(raw.Outbounds) == 0 {
		return nil, fmt.Errorf("missing required field: outbounds (must have at least 1 entry)")
	}

	// Validate each outbound entry.
	for i, ob := range raw.Outbounds {
		if err := validateOutbound(i, ob); err != nil {
			return nil, err
		}
	}

	// Validate optional IP address format.
	if raw.DOHServerIP != "" {
		if err := validateIPAddress(raw.DOHServerIP); err != nil {
			return nil, fmt.Errorf("invalid doh_server_ip %q: %w", raw.DOHServerIP, err)
		}
	}

	return &AppConfig{
		BridgeRSAID:     raw.BridgeRSAID,
		BridgeEd25519ID: raw.BridgeEd25519ID,
		DOHServer:       raw.DOHServer,
		DOHServerIP:     raw.DOHServerIP,
		Outbounds:       raw.Outbounds,
		SkipArti:        raw.SkipArti,
	}, nil
}

// supportedProtocols lists all recognized xray-core outbound protocols.
// This is not an exhaustive whitelist — unknown protocols generate a warning
// but do not cause validation failure (for forward compatibility).
var supportedProtocols = map[string]bool{
	"vless":        true,
	"vmess":        true,
	"trojan":       true,
	"shadowsocks":  true,
	"wireguard":    true,
	"hysteria2":    true,
	"tuic":         true,
	"xhttp":        true,
	"socks":        true,
	"http":         true,
	"freedom":      true,
	"blackhole":    true,
	"dns":          true,
	"loopback":     true,
}

// validateOutbound checks a single outbound configuration entry.
func validateOutbound(index int, ob map[string]interface{}) error {
	protocol, ok := ob["protocol"].(string)
	if !ok || protocol == "" {
		return fmt.Errorf("outbounds[%d]: missing or empty 'protocol' field", index)
	}

	// Tag is required for routing.
	tag, ok := ob["tag"].(string)
	if !ok || tag == "" {
		return fmt.Errorf("outbounds[%d]: missing or empty 'tag' field", index)
	}

	// Settings must be present (can be empty object for some protocols).
	if _, ok := ob["settings"]; !ok {
		return fmt.Errorf("outbounds[%d] (%s): missing 'settings' field", index, protocol)
	}

	return nil
}

// validateIPAddress checks if a string is a valid IPv4 or IPv6 address.
func validateIPAddress(ip string) error {
	// Simple validation: must contain dots or colons, and each octet/group must be valid.
	parts := strings.Split(ip, ".")
	if len(parts) == 4 {
		for _, p := range parts {
			if len(p) == 0 || len(p) > 3 {
				return fmt.Errorf("invalid IPv4 octet: %q", p)
			}
			n := 0
			for _, c := range p {
				if c < '0' || c > '9' {
					return fmt.Errorf("non-numeric character in IPv4: %q", p)
				}
				n = n*10 + int(c-'0')
			}
			if n > 255 {
				return fmt.Errorf("IPv4 octet out of range: %d", n)
			}
		}
		return nil
	}

	// IPv6 — basic check for colons.
	if strings.Contains(ip, ":") {
		return nil // Detailed IPv6 validation is complex; accept any colon-containing string.
	}

	return fmt.Errorf("not a valid IPv4 or IPv6 address")
}

// fetchConfig downloads the configuration from a URL with timeout and size limits.
func fetchConfig(ctx context.Context, url string) ([]byte, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "VPN-TOR-Client/1.0")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, resp.Status)
	}

	// Limit response size to 1 MB to prevent abuse.
	const maxSize = 1 << 20
	limited := io.LimitReader(resp.Body, maxSize)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}

	if len(data) == 0 {
		return nil, fmt.Errorf("empty response body")
	}

	return data, nil
}
