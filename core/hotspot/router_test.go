package hotspot

import (
	"net/netip"
	"strings"
	"testing"
)

func routerTestEnvironment() Environment {
	return Environment{Running: true, DNSReady: true, IPv6Ready: true, TunDevice: "utun4", TunAddress: netip.MustParseAddr("198.19.0.1"), Tun6Address: netip.MustParseAddr("fdfe:dcba:9876::1")}
}

func routerTestChoice() LANInterface {
	return LANInterface{Name: "en0", Address: "10.1.1.8", Network: "10.1.0.0/16", IPv6: []string{"fe80::8%en0", "fd12:3456::8"}, IPv6Networks: []string{"fe80::/64", "fd12:3456::/64"}}
}

func TestRouterSelectsOnlyOwnedPrivateDualStackLAN(t *testing.T) {
	env := routerTestEnvironment()
	c := routerTestChoice()
	l, err := selectRouterLink(env, []LANInterface{c}, "en0")
	if err != nil || !l.Router || l.Interface != "en0" || l.Tun6Address != env.Tun6Address {
		t.Fatalf("valid dual stack LAN: %+v %v", l, err)
	}
	for _, scenario := range []string{"foreign-IP", "tunnel", "hotspot", "public", "overbroad"} {
		t.Run(scenario, func(t *testing.T) {
			candidate := routerTestChoice()
			request := env
			switch scenario {
			case "foreign-IP":
				request.RouterAddress = "10.1.1.9"
			case "tunnel":
				candidate.Name = "utun9"
			case "hotspot":
				candidate.Name = "bridge100"
			case "public":
				candidate.Address, candidate.Network = "8.8.8.8", "8.8.8.0/24"
			case "overbroad":
				candidate.Network = "10.0.0.0/7"
			}
			if _, err := selectRouterLink(request, []LANInterface{candidate}, ""); err == nil {
				t.Fatal("unsafe/incomplete LAN accepted")
			}
		})
	}
	other := c
	other.Name, other.Address = "en5", "192.168.5.8"
	other.Network = "192.168.5.0/24"
	if _, err := selectRouterLink(env, []LANInterface{c, other}, ""); err == nil {
		t.Fatal("ambiguous LAN silently selected")
	}
	l, err = selectRouterLink(env, []LANInterface{c, other}, "en5")
	if err != nil || l.Interface != "en5" {
		t.Fatal("physical default preference lost")
	}
}

func TestRouterRulesCoverBothFamiliesAndPreserveHostTraffic(t *testing.T) {
	l, err := selectRouterLink(routerTestEnvironment(), []LANInterface{routerTestChoice()}, "en0")
	if err != nil {
		t.Fatal(err)
	}
	l.StateLabel = "flclash-router-424242"
	raw, err := rules(l, 1054)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"table <flclash_router_clients> { 10.1.0.0/16, fe80::/64, fd12:3456::/64, !self }",
		"to 10.1.1.8 port 53 -> 10.1.1.8 port 1054",
		"to fe80::8 port 53 -> fd12:3456::8 port 1054",
		"on en0 route-to (utun4 198.19.0.1) inet from <flclash_router_clients>",
		"on en0 route-to (utun4 fdfe:dcba:9876::1) inet6 from <flclash_router_clients>",
		"on utun4 route-to en0 inet to <flclash_router_clients>",
		"on utun4 route-to en0 inet6 to <flclash_router_clients>",
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("missing scoped path: %s", want)
		}
	}
	if strings.Contains(raw, "block") || strings.Contains(raw, "keep state") || strings.Contains(raw, "pass out") || strings.Count(raw, "no state") != 4 {
		t.Fatal("router changed host IPv6/state policy")
	}
	gw, dns := l.routerIPv6Addresses()
	if gw != "fe80::8" || dns != "fd12:3456::8" {
		t.Fatalf("client-facing IPs leaked Mac scope or chose bad DNS: %s/%s", gw, dns)
	}
	for _, peer := range []string{"10.1.1.9:1234", "[fd12:3456::9]:1234", "[fe80::9%en0]:1234"} {
		if !l.allowsDNSPeer(peer) {
			t.Fatalf("rejected LAN peer: %s", peer)
		}
	}
	for _, peer := range []string{"192.168.5.9:1234", "[2001:db8::9]:1234", "[fe80::9%utun4]:1234"} {
		if l.allowsDNSPeer(peer) {
			t.Fatalf("exposed DNS outside selected LAN: %s", peer)
		}
	}
	l.Tun6Address = netip.Addr{}
	if _, err := rules(l, 1054); err == nil {
		t.Fatal("IPv4-only router rules silently accepted")
	}
}

func TestRouterIPv4ModeDoesNotToggleHotspot(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	p.link.Router = true
	router := testManager(p)
	router.router = true
	hotspot := testManager(&fakePlatform{link: testLink()})
	defer hotspot.Close()
	defer router.Close()
	if !hotspot.SetEnabled(true).Active {
		t.Fatal("hotspot start failed")
	}
	if s := router.SetRouter(true, "127.0.0.1"); s.Error != "" || !s.Active || s.IPv6DNS != "" || p.installs != 1 {
		t.Fatalf("IPv4-only network did not start safely: %+v", s)
	}
	router.environment = routerTestEnvironment
	if s := router.SetRouter(true, "127.0.0.1"); !s.Active || !hotspot.Status().Active {
		t.Fatalf("mode isolation/start: %+v", s)
	}
	dns := router.dns
	if s := router.SetRouter(true, "127.0.0.2"); s.Error != "disableBeforeChanging" || router.dns != dns || p.installs != 1 {
		t.Fatal("live gateway address changed")
	}
	if s := router.SetRouter(false, ""); s.Active || !hotspot.Status().Active {
		t.Fatal("router disable affected hotspot")
	}
}
