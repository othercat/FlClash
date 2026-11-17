package hotspot

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	D "github.com/miekg/dns"
)

func TestPendingIntentUsesSlowChecksAndResumesOnStart(t *testing.T) {
	p := &fakePlatform{link: testLink()}
	m := testManager(p)
	defer m.Close()
	env := m.environment()
	m.environment = func() Environment { return Environment{} }
	s := m.SetEnabled(true)
	if !s.Enabled || s.Active || p.installs != 0 || m.checkIntervalLocked() != time.Minute {
		t.Fatalf("waiting changed intent or installed rules: %+v", s)
	}
	m.environment = func() Environment { return env }
	m.Resume()
	if s = m.Status(); !s.Enabled || !s.Active || p.installs != 1 || m.checkIntervalLocked() != 5*time.Second {
		t.Fatalf("start did not immediately restore sharing: %+v", s)
	}
	m.Suspend()
	if s = m.Status(); !s.Enabled || s.Active || m.dns != nil || m.checkIntervalLocked() != time.Minute {
		t.Fatalf("temporary stop lost intent or kept forwarding: %+v", s)
	}
	m.SetEnabled(true)
	if p.installs != 1 || m.Status().Active {
		t.Fatal("settings refresh reinstalled against suspended listeners")
	}
	m.Resume()
	if !m.Status().Active || p.installs != 2 {
		t.Fatal("resume did not rebuild")
	}
	m.SetEnabled(false)
	m.Suspend()
	m.Resume()
	if m.Status().Enabled || m.Status().Active || p.installs != 2 {
		t.Fatal("explicit disable was resurrected")
	}
}

func TestInitialMissingSharingKeepsIntentAndCleanupIsRetried(t *testing.T) {
	p := &fakePlatform{link: testLink(), detectErr: errors.New("sharingRequired")}
	m := testManager(p)
	defer m.Close()
	if s := m.SetEnabled(true); !s.Enabled || s.Active || s.Error != "sharingRequired" {
		t.Fatalf("missing sharing: %+v", s)
	}
	p.detectErr = nil
	m.Resume()
	p.removeErr = errors.New("concurrent PF update")
	m.Suspend()
	if !m.Status().Enabled || !m.dirty || m.dns == nil {
		t.Fatal("cleanup failure lost intent or stranded DNS")
	}
	p.removeErr = nil
	m.Resume()
	if !m.Status().Active || m.dirty || p.installs != 2 {
		t.Fatal("cleanup retry did not restore")
	}
}

func TestAutomaticRouterFollowsCurrentLANAndAvailableFamilies(t *testing.T) {
	env := routerTestEnvironment()
	c := routerTestChoice()
	c.IPv6, c.IPv6Networks = nil, nil
	l, err := selectRouterLink(env, []LANInterface{c}, "en0")
	if err != nil || l.Tun6Address.IsValid() || l.IPv6 != "" {
		t.Fatalf("IPv4-only LAN: %+v %v", l, err)
	}
	l.StateLabel = "flclash-router-424242"
	raw, err := rules(l, 1054)
	if err != nil || strings.Contains(raw, "inet6") || strings.Count(raw, "no state") != 2 || !strings.Contains(raw, "!self") {
		t.Fatalf("IPv4-only PF path: %v\n%s", err, raw)
	}
	env.IPv6Ready = false
	l, err = selectRouterLink(env, []LANInterface{routerTestChoice()}, "en0")
	if err != nil || l.Tun6Address.IsValid() || l.IPv6Networks != "" {
		t.Fatal("IPv6 advertised without DNS/TUN readiness")
	}
	next := LANInterface{Name: "en21", Address: "192.168.0.221", Network: "192.168.0.0/24"}
	l, err = selectRouterLink(env, []LANInterface{routerTestChoice(), next}, "en21")
	if err != nil || l.Interface != "en21" || l.Address.String() != next.Address {
		t.Fatal("automatic selection stayed pinned to the old network")
	}
}

func TestIPv4RouterDNSDoesNotAdvertiseUnroutedAAAA(t *testing.T) {
	l := testLink()
	l.Router = true
	calls := 0
	s, err := listenDNS(l, D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		calls++
		a := new(D.Msg)
		a.SetReply(q)
		_ = w.WriteMsg(a)
	}))
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	for _, network := range []string{"udp4", "tcp4"} {
		q := new(D.Msg)
		q.SetQuestion("example.com.", D.TypeAAAA)
		c := D.Client{Net: network, Timeout: time.Second}
		a, _, err := c.Exchange(q, net.JoinHostPort("127.0.0.1", stringPort(s.port)))
		if err != nil || a.Rcode != D.RcodeSuccess || !a.RecursionAvailable || len(a.Answer) != 0 {
			t.Fatal("invalid IPv4-only AAAA reply", err)
		}
	}
	if calls != 0 {
		t.Fatal("forwarded AAAA without a matching IPv6 data path")
	}
}
