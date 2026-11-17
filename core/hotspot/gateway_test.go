package hotspot

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"testing"
	"time"

	D "github.com/miekg/dns"
)

func testLink() link {
	return link{Interface: "bridge100", Address: netip.MustParseAddr("127.0.0.1"), Network: netip.MustParsePrefix("127.0.0.0/24"), TunDevice: "utun4", TunAddress: netip.MustParseAddr("198.19.0.1")}
}

type fakePlatform struct {
	link                                          link
	installErr, removeErr, detectErr, maintainErr error
	installs, removes, maintains                  int
}

func (f *fakePlatform) detect(Environment) (link, error) { return f.link, f.detectErr }
func (f *fakePlatform) install(link, int) error          { f.installs++; return f.installErr }
func (f *fakePlatform) maintain(link, int) error         { f.maintains++; return f.maintainErr }
func (f *fakePlatform) remove() error                    { f.removes++; return f.removeErr }

func TestActiveGatewayMaintainsRulesWithoutReplacingDNS(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	if !m.SetEnabled(true).Active {
		t.Fatal("enable failed")
	}
	defer m.Close()
	dns := m.dns
	port := dns.port
	p.maintainErr = errors.New("forwarding recovery cooling down")
	s := m.SetEnabled(true)
	if p.maintains != 1 || m.dns != dns || m.dns.port != port || p.installs != 1 || p.removes != 0 || !s.Active || s.Error == "" {
		t.Fatalf("transient repair displaced the session: %+v, checks=%d", s, p.maintains)
	}
	p.maintainErr = nil
	s = m.SetEnabled(true)
	if !s.Active || s.Error != "" || m.dns != dns || p.maintains != 2 || p.installs != 1 || p.removes != 0 {
		t.Fatalf("recovery did not preserve the session: %+v", s)
	}
}

func TestGatewayDoesNotRepairWhenSharingOrTunIsOff(t *testing.T) {
	for _, condition := range []string{"sharing", "tun", "disabled"} {
		t.Run(condition, func(t *testing.T) {
			p := &fakePlatform{link: testLink()}
			m := testManager(p)
			if status := m.SetEnabled(true); !status.Active {
				t.Fatalf("enable failed: %+v", status)
			}
			defer m.Close()
			switch condition {
			case "sharing":
				p.detectErr = errors.New("sharingRequired")
			case "tun":
				m.environment = func() Environment { return Environment{} }
			case "disabled":
				m.SetEnabled(false)
			}
			m.mu.Lock()
			m.syncLocked()
			m.mu.Unlock()
			if p.maintains != 0 || m.Status().Active || m.dns != nil {
				t.Fatalf("repair ran after %s was turned off: %+v", condition, m.Status())
			}
		})
	}
}

func TestGatewayPreservesDNSAcrossTemporaryPFDisable(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	if !m.SetEnabled(true).Active {
		t.Fatal("enable failed")
	}
	defer m.Close()
	dns := m.dns
	p.detectErr = fmt.Errorf("%w: PF disabled during external reload", errPlatformTemporary)
	s := m.SetEnabled(true)
	if !s.Active || s.Error == "" || m.dns != dns || p.removes != 0 || p.maintains != 0 || p.installs != 1 {
		t.Fatal("temporary PF outage changed DNS, states or forwarding")
	}
	p.detectErr = nil
	s = m.SetEnabled(true)
	if !s.Active || s.Error != "" || m.dns != dns || p.maintains != 1 {
		t.Fatal("PF recovery did not resume the same session")
	}
}

func TestGatewayKeepsDNSWhenOnlyLocalAddressesChange(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	if !m.SetEnabled(true).Active {
		t.Fatal("enable failed")
	}
	defer m.Close()
	dns := m.dns
	p.link.HostAddresses = "127.0.0.1/8 10.1.2.3/32"
	s := m.SetEnabled(true)
	if !s.Active || s.Error != "" || m.dns != dns || p.removes != 0 || p.installs != 1 || p.maintains != 1 {
		t.Fatalf("address refresh restarted hotspot DNS: %+v", s)
	}
}

func TestGatewayCleansOldPathWhenTunChanges(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	if !m.SetEnabled(true).Active {
		t.Fatal("enable failed")
	}
	defer m.Close()
	dns := m.dns
	p.link.TunDevice = "utun8"
	s := m.SetEnabled(true)
	if !s.Active || s.TunDevice != "utun8" || m.dns == dns || p.removes != 1 || p.installs != 2 || p.maintains != 0 {
		t.Fatalf("TUN change incorrectly reused the old path: %+v", s)
	}
}

func testManager(p *fakePlatform) *Manager {
	return &Manager{platform: p, environment: func() Environment {
		return Environment{Running: true, DNSReady: true, TunDevice: "utun4", TunAddress: netip.MustParseAddr("198.19.0.1")}
	}, handler: D.HandlerFunc(func(w D.ResponseWriter, r *D.Msg) { m := new(D.Msg); m.SetReply(r); _ = w.WriteMsg(m) }), status: Status{Supported: true}}
}

func TestGatewayOwnsDNSAndRollsBackFailedInstall(t *testing.T) {
	p := &fakePlatform{link: testLink(), installErr: errors.New("denied")}
	m := testManager(p)
	s := m.SetEnabled(true)
	if s.Active || !s.Enabled || !strings.Contains(s.Error, "denied") || m.dns != nil || p.removes != 1 {
		t.Fatalf("failed install leaked state: %+v, DNS=%v, removes=%d", s, m.dns, p.removes)
	}
	p.installErr = nil
	p.link.IPv6 = "::1"
	p.link.IPv6Networks = "::1/128"
	s = m.SetEnabled(true)
	if !s.Active || !s.Enabled {
		t.Fatalf("enable: %+v", s)
	}
	port := m.dns.port
	for _, network := range []string{"udp4", "tcp4", "udp6", "tcp6"} {
		q := new(D.Msg)
		q.SetQuestion("example.com.", D.TypeA)
		client := D.Client{Net: network, Timeout: time.Second}
		host := "127.0.0.1"
		if strings.HasSuffix(network, "6") {
			host = "::1"
		}
		if _, _, err := client.Exchange(q, net.JoinHostPort(host, stringPort(port))); err != nil {
			t.Fatalf("%s hotspot DNS: %v", network, err)
		}
	}
	m.SetEnabled(true)
	if p.installs != 2 {
		t.Fatalf("same link unnecessarily replaced rules: %d", p.installs)
	}
	s = m.SetEnabled(false)
	if s.Active || s.Enabled || m.dns != nil {
		t.Fatalf("disable leaked state: %+v", s)
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", stringPort(port)), time.Second)
	if err == nil {
		c.Close()
		t.Fatal("DNS remained open after disable")
	}
}

func stringPort(port int) string { return strconv.Itoa(port) }

func TestGatewayNeverEnablesWithoutHostTun(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	defer m.Close()
	m.environment = func() Environment { return Environment{} }
	s := m.SetEnabled(true)
	if s.Active || !s.Enabled || s.Error != "tunRequired" || p.installs != 0 {
		t.Fatalf("unexpected enable: %+v", s)
	}
}

func TestGatewayRetainsDNSWhileCleanupNeedsRetry(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	if !m.SetEnabled(true).Active {
		t.Fatal("enable failed")
	}
	p.removeErr = errors.New("busy")
	s := m.SetEnabled(false)
	if !s.Active || m.dns == nil || !strings.Contains(s.Error, "cleanup") {
		t.Fatalf("stranded redirect: %+v", s)
	}
	p.removeErr = nil
	m.SetEnabled(false)
	if m.dns != nil || m.Status().Active {
		t.Fatal("cleanup retry failed")
	}
}

func TestRulesLimitInterceptionToHotspot(t *testing.T) {
	l := testLink()
	l.Address = netip.MustParseAddr("192.168.2.1")
	l.Network = netip.MustParsePrefix("192.168.2.0/24")
	l.IPv6 = "fe80::1%bridge100 fd12:3456::1"
	l.IPv6Networks = "fe80::/64 fd12:3456::/64"
	r, err := rules(l, 23456)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimSpace(r), "\n") {
		if strings.HasPrefix(line, "table <flclash_hotspot_local>") {
			continue
		}
		if !strings.Contains(line, "on bridge100 ") {
			t.Fatalf("unscoped rule: %s", line)
		}
		if strings.Contains(line, "pass out") || strings.Contains(line, "nat on") {
			t.Fatalf("host/egress modification: %s", line)
		}
	}
	for _, want := range []string{"-> 192.168.2.1 port 23456", "inet6 proto { tcp udp }", "route-to (utun4 198.19.0.1)", "inet from 192.168.2.0/24", "block return in quick on bridge100 inet6 from any to !"} {
		if !strings.Contains(r, want) {
			t.Fatalf("missing %q", want)
		}
	}
	for _, change := range []func(*link){func(l *link) { l.Interface = "bridge100\npass all" }, func(l *link) { l.TunDevice = "utun4; echo" }, func(l *link) { l.Network = netip.MustParsePrefix("10.0.0.0/24") }, func(l *link) { l.TunAddress = netip.MustParseAddr("::1") }} {
		bad := l
		change(&bad)
		if _, err := rules(bad, 23456); err == nil {
			t.Fatalf("accepted invalid link: %+v", bad)
		}
	}
}

func TestRulesRedirectLinkLocalDNSToAnExplicitListener(t *testing.T) {
	l := testLink()
	l.IPv6 = "fe80::1%bridge100 fd12:3456::1"
	l.IPv6Networks = "fe80::/64 fd12:3456::/64"
	l.DNSInterfaces = "ap1"
	r, err := rules(l, 23456)
	if err != nil {
		t.Fatal(err)
	}
	for _, destination := range []string{"fe80::1", "fd12:3456::1"} {
		want := "inet6 proto { tcp udp } from any to " + destination + " port 53 -> fd12:3456::1 port 23456"
		if !strings.Contains(r, want) {
			t.Fatalf("missing explicit DNS redirect %q in:\n%s", want, r)
		}
	}
	if strings.Contains(r, "-> (bridge100)") || strings.Contains(r, "%bridge100") {
		t.Fatalf("IPv6 DNS still depends on dynamic addresses or socket zones: %s", r)
	}
	l.IPv6 = "fe80::1%en21"
	if _, err := rules(l, 23456); err == nil {
		t.Fatal("accepted IPv6 listener on the upstream interface")
	}
}

func TestReenableAfterCleanupFailureReinstallsRules(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	if !m.SetEnabled(true).Active {
		t.Fatal("enable failed")
	}
	p.removeErr = errors.New("concurrent PF update")
	m.SetEnabled(false)
	if !m.dirty {
		t.Fatal("cleanup failure not tracked")
	}
	p.removeErr = nil
	s := m.SetEnabled(true)
	if !s.Active || !s.Enabled || m.dirty || p.installs != 2 {
		t.Fatalf("reenable did not reinstall: %+v, dirty=%v, installs=%d", s, m.dirty, p.installs)
	}
	m.Close()
}

func TestDNSRejectsOtherInterfacesAndUpstreamSources(t *testing.T) {
	l := testLink()
	l.Address = netip.MustParseAddr("192.168.2.1")
	l.Network = netip.MustParsePrefix("192.168.2.0/24")
	l.IPv6Networks = "fe80::/64 fd12:3456::/64"
	l.DNSInterfaces = "ap1"
	for remote, want := range map[string]bool{"192.168.2.7:1234": true, "192.168.0.7:1234": false, "[fe80::2%bridge100]:1234": true, "[fe80::2%ap1]:1234": true, "[fe80::2%en21]:1234": false, "[fd12:3456::2]:1234": true, "[240a::2]:1234": false, "invalid": false} {
		if got := l.allowsDNSPeer(remote); got != want {
			t.Errorf("%s: got %v, want %v", remote, got, want)
		}
	}
}
