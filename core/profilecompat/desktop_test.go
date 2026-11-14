package profilecompat

import (
	"bytes"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestWithoutExtensionIsUnchanged(t *testing.T) {
	input := []byte("# keep comments and CRLF\r\nmode: rule\r\nproxies: []\r\n")
	output, err := ExpandDesktop(input)
	if err != nil || !bytes.Equal(output, input) {
		t.Fatalf("ordinary profile changed: error %v", err)
	}
}

func TestDesktopMergePreservesValuesAndOrder(t *testing.T) {
	input := []byte(`mode: rule
secret: "fixture-secret"
proxies:
  - {name: common, type: vmess, alterId: "0", password: "00123"}
proxy-groups:
  - {name: choose, type: select, proxies: [common]}
dns:
  enable: true
  nameserver: [https://dns.example/dns-query]
  nameserver-policy:
    "+.example.com": https://first.example/dns-query
    "+.unchanged.example": https://other.example/dns-query
rules: ["DOMAIN-SUFFIX,example.com,choose", "MATCH,DIRECT"]
tun: {stack: gvisor, auto-detect-interface: true}
x-flclash-desktop:
  proxies:
    - {name: desktop, type: vless, uuid: "fake-uuid", tls: true}
  proxy-order: [desktop, common]
  proxy-groups:
    - {name: choose, type: select, proxies: [desktop, common]}
  dns:
    nameserver-policy:
      "+.example.com": [https://first.example/dns-query, https://second.example/dns-query]
      "+.corporate.example": system
`)
	output, err := ExpandDesktop(input)
	if err != nil {
		t.Fatal(err)
	}
	var before, after map[string]any
	if err := yaml.Unmarshal(input, &before); err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(output, &after); err != nil {
		t.Fatal(err)
	}
	if _, exists := after[DesktopKey]; exists {
		t.Fatal("extension reached the normal parser")
	}
	for _, key := range []string{"mode", "secret", "rules", "tun"} {
		if !reflect.DeepEqual(before[key], after[key]) {
			t.Fatalf("unrelated field %s changed", key)
		}
	}
	nodes := after["proxies"].([]any)
	if len(nodes) != 2 || nodes[0].(map[string]any)["name"] != "desktop" {
		t.Fatal("desktop node ordering was not restored")
	}
	if !reflect.DeepEqual(before["proxies"].([]any)[0], nodes[1]) {
		t.Fatal("node values or scalar types changed")
	}
	ext := before[DesktopKey].(map[string]any)
	if !reflect.DeepEqual(after["proxy-groups"], ext["proxy-groups"]) {
		t.Fatal("desktop groups did not replace common groups")
	}
	dns := after["dns"].(map[string]any)
	if dns["enable"] != true || !reflect.DeepEqual(dns["nameserver"], before["dns"].(map[string]any)["nameserver"]) {
		t.Fatal("unrelated DNS options changed")
	}
	policy := dns["nameserver-policy"].(map[string]any)
	if len(policy["+.example.com"].([]any)) != 2 || policy["+.corporate.example"] != "system" || policy["+.unchanged.example"] == nil {
		t.Fatal("desktop DNS policies were not merged")
	}
}

func TestAppendWithoutOrderAndMissingDNS(t *testing.T) {
	output, err := ExpandDesktop([]byte(`proxies: [{name: common}]
x-flclash-desktop:
  proxies: [{name: extra}]
  dns:
    nameserver-policy: {"+.example.com": system}
`))
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := yaml.Unmarshal(output, &root); err != nil {
		t.Fatal(err)
	}
	nodes := root["proxies"].([]any)
	if len(nodes) != 2 || nodes[0].(map[string]any)["name"] != "common" || nodes[1].(map[string]any)["name"] != "extra" {
		t.Fatal("append order changed")
	}
	if root["dns"] == nil {
		t.Fatal("missing DNS mapping was not created")
	}
}

func TestInvalidExtensionsFailWithoutLeakingValues(t *testing.T) {
	cases := map[string]string{
		"extension type":   `x-flclash-desktop: private-value`,
		"unknown field":    `x-flclash-desktop: {unknown: private-value}`,
		"proxy type":       `x-flclash-desktop: {proxies: private-value}`,
		"unnamed proxy":    `x-flclash-desktop: {proxies: [{password: private-value}]}`,
		"duplicate proxy":  "proxies: [{name: duplicate}]\nx-flclash-desktop: {proxies: [{name: duplicate, password: private-value}]}",
		"incomplete order": "proxies: [{name: common}]\nx-flclash-desktop: {proxy-order: []}",
		"unknown order":    "proxies: [{name: common}]\nx-flclash-desktop: {proxy-order: [private-value]}",
		"duplicate order":  "proxies: [{name: a}, {name: b}]\nx-flclash-desktop: {proxy-order: [a, a]}",
		"order type":       `x-flclash-desktop: {proxy-order: private-value}`,
		"null order":       `x-flclash-desktop: {proxy-order: null}`,
		"group type":       `x-flclash-desktop: {proxy-groups: private-value}`,
		"duplicate group":  `x-flclash-desktop: {proxy-groups: [{name: a}, {name: a, password: private-value}]}`,
		"dns type":         `x-flclash-desktop: {dns: private-value}`,
		"dns unknown":      `x-flclash-desktop: {dns: {nameserver: private-value}}`,
		"policy type":      `x-flclash-desktop: {dns: {nameserver-policy: private-value}}`,
		"empty resolvers":  `x-flclash-desktop: {dns: {nameserver-policy: {example.com: []}}}`,
		"invalid resolver": `x-flclash-desktop: {dns: {nameserver-policy: {example.com: [private-value, 42]}}}`,
		"root dns type":    "dns: private-value\nx-flclash-desktop: {dns: {nameserver-policy: {example.com: system}}}",
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			output, err := ExpandDesktop([]byte(input))
			if err == nil || output != nil {
				t.Fatal("invalid extension was accepted")
			}
			if strings.Contains(err.Error(), "private-value") {
				t.Fatal("error leaked a profile value")
			}
		})
	}
}
