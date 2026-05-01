package config

import (
	"encoding/json"
	"testing"
)

func TestParseValidConfig(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server":    "https://dns.google/dns-query",
		"doh_server_ip": "8.8.8.8",
		"skip_arti":     true,
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "vless",
				"tag":      "proxy",
				"settings": map[string]interface{}{
					"vnext": []interface{}{
						map[string]interface{}{
							"address": "example.com",
							"port":    443,
							"users": []interface{}{
								map[string]interface{}{
									"id": "test-uuid",
								},
							},
						},
					},
				},
				"streamSettings": map[string]interface{}{
					"network":  "tcp",
					"security": "tls",
				},
			},
		},
	}

	data, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("marshal test data: %v", err)
	}

	cfg, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse() error: %v", err)
	}

	if cfg.DOHServer != "https://dns.google/dns-query" {
		t.Errorf("DOHServer = %q, want %q", cfg.DOHServer, "https://dns.google/dns-query")
	}
	if cfg.DOHServerIP != "8.8.8.8" {
		t.Errorf("DOHServerIP = %q, want %q", cfg.DOHServerIP, "8.8.8.8")
	}
	if !cfg.SkipArti {
		t.Error("SkipArti = false, want true")
	}
	if len(cfg.Outbounds) != 1 {
		t.Fatalf("Outbounds len = %d, want 1", len(cfg.Outbounds))
	}
	if cfg.Outbounds[0]["protocol"] != "vless" {
		t.Errorf("Outbounds[0].protocol = %v, want vless", cfg.Outbounds[0]["protocol"])
	}
}

func TestParseMissingDOHServer(t *testing.T) {
	raw := map[string]interface{}{
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "vmess",
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	_, err := Parse(data)
	if err == nil {
		t.Fatal("Parse() should fail when doh_server is missing")
	}
}

func TestParseMissingOutbounds(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server": "https://dns.google/dns-query",
	}

	data, _ := json.Marshal(raw)
	_, err := Parse(data)
	if err == nil {
		t.Fatal("Parse() should fail when outbounds is missing")
	}
}

func TestParseNonHTTPSDOH(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server": "http://dns.google/dns-query",
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "vless",
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	_, err := Parse(data)
	if err == nil {
		t.Fatal("Parse() should fail when doh_server is not HTTPS")
	}
}

func TestParseOutboundMissingProtocol(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server": "https://dns.google/dns-query",
		"outbounds": []interface{}{
			map[string]interface{}{
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	_, err := Parse(data)
	if err == nil {
		t.Fatal("Parse() should fail when outbound is missing protocol")
	}
}

func TestParseOutboundMissingTag(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server": "https://dns.google/dns-query",
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "trojan",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	_, err := Parse(data)
	if err == nil {
		t.Fatal("Parse() should fail when outbound is missing tag")
	}
}

func TestParseInvalidDOHServerIP(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server":    "https://dns.google/dns-query",
		"doh_server_ip": "999.999.999.999",
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "vless",
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	_, err := Parse(data)
	if err == nil {
		t.Fatal("Parse() should fail for invalid doh_server_ip")
	}
}

func TestParseIgnoresExtraFields(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server": "https://dns.google/dns-query",
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "shadowsocks",
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
		},
		"inbounds": []interface{}{
			map[string]interface{}{"should": "be ignored"},
		},
		"routing": map[string]interface{}{"should": "be ignored"},
		"policy":  map[string]interface{}{"should": "be ignored"},
		"stats":   map[string]interface{}{"should": "be ignored"},
	}

	data, _ := json.Marshal(raw)
	cfg, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse() should not fail for extra fields: %v", err)
	}
	if len(cfg.Outbounds) != 1 {
		t.Errorf("Outbounds len = %d, want 1", len(cfg.Outbounds))
	}
}

func TestParseWithBridgeKeys(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server":       "https://dns.google/dns-query",
		"bridge_rsa_id":    "AABBCCDD",
		"bridge_ed25519_id": "EEFF0011",
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "vless",
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	cfg, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse() error: %v", err)
	}

	if cfg.BridgeRSAID != "AABBCCDD" {
		t.Errorf("BridgeRSAID = %q, want %q", cfg.BridgeRSAID, "AABBCCDD")
	}
	if cfg.BridgeEd25519ID != "EEFF0011" {
		t.Errorf("BridgeEd25519ID = %q, want %q", cfg.BridgeEd25519ID, "EEFF0011")
	}
}

func TestValidateIPAddress(t *testing.T) {
	tests := []struct {
		ip      string
		wantErr bool
	}{
		{"1.2.3.4", false},
		{"192.168.0.1", false},
		{"255.255.255.255", false},
		{"::1", false},
		{"2001:db8::1", false},
		{"999.0.0.1", true},
		{"abc", true},
		{"", true},
	}

	for _, tt := range tests {
		err := validateIPAddress(tt.ip)
		if (err != nil) != tt.wantErr {
			t.Errorf("validateIPAddress(%q) error = %v, wantErr %v", tt.ip, err, tt.wantErr)
		}
	}
}

func TestParseInvalidJSON(t *testing.T) {
	_, err := Parse([]byte("not json"))
	if err == nil {
		t.Fatal("Parse() should fail for invalid JSON")
	}
}

func TestParseMultipleOutbounds(t *testing.T) {
	raw := map[string]interface{}{
		"doh_server": "https://cloudflare-dns.com/dns-query",
		"outbounds": []interface{}{
			map[string]interface{}{
				"protocol": "vless",
				"tag":      "proxy",
				"settings": map[string]interface{}{},
			},
			map[string]interface{}{
				"protocol": "freedom",
				"tag":      "direct",
				"settings": map[string]interface{}{},
			},
		},
	}

	data, _ := json.Marshal(raw)
	cfg, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse() error: %v", err)
	}
	if len(cfg.Outbounds) != 2 {
		t.Errorf("Outbounds len = %d, want 2", len(cfg.Outbounds))
	}
}
