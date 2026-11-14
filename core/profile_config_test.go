//go:build darwin || windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSharedProfileReadAndValidation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "shared.yaml")
	input := []byte(`proxies: [{name: common, type: ss}]
proxy-groups: [{name: choose, type: select, proxies: [common]}]
x-flclash-desktop:
  proxies: [{name: desktop, type: vless}]
  proxy-order: [desktop, common]
  proxy-groups: [{name: choose, type: select, proxies: [desktop, common]}]
  dns:
    nameserver-policy: {"+.example.com": [system, https://dns.example/dns-query]}
`)
	if err := os.WriteFile(path, input, 0600); err != nil {
		t.Fatal(err)
	}
	raw, err := handleGetConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw.Proxy) != 2 || raw.Proxy[0]["name"] != "desktop" || len(raw.ProxyGroup) != 1 {
		t.Fatal("profile getter did not expand desktop nodes and groups")
	}
	if raw.DNS.NameServerPolicy == nil || raw.DNS.NameServerPolicy.Len() != 1 {
		t.Fatal("desktop DNS list policy did not reach the core parser")
	}
	if message := handleValidateConfig(path); message != "" {
		t.Fatalf("shared profile validation failed: %s", message)
	}
	if err := os.WriteFile(path, []byte("x-flclash-desktop: {proxy-order: [missing]}"), 0600); err != nil {
		t.Fatal(err)
	}
	if message := handleValidateConfig(path); !strings.HasPrefix(message, "x-flclash-desktop:") {
		t.Fatal("validation bypassed desktop extension checks")
	}
	if message := handleValidateConfig(filepath.Join(t.TempDir(), "missing.yaml")); message == "" {
		t.Fatal("validation ignored the profile read error")
	}
}
