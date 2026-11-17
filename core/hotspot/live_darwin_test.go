package hotspot

import (
	"context"
	"encoding/json"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	D "github.com/miekg/dns"
)

// Explicit manual integration entry: the installed proxy is left running.
// Default tests never apply PF rules. This opt-in helper forwards DNS to that
// proxy and attaches only a temporary hotspot gateway, then removes it on
// completion, interrupt or the bounded deadline.
func TestDarwinHotspotManualSession(t *testing.T) {
	if os.Getenv("FLCLASH_HOTSPOT_MANUAL") != "1" {
		t.Skip("manual hotspot integration only")
	}
	if os.Geteuid() != 0 {
		t.Fatal("root required")
	}
	device := os.Getenv("FLCLASH_HOTSPOT_TUN")
	address, err := netip.ParseAddr(os.Getenv("FLCLASH_HOTSPOT_TUN_ADDRESS"))
	if err != nil || !tunName.MatchString(device) || !address.Is4() {
		t.Fatal("explicit active TUN required")
	}
	dnsAddress := os.Getenv("FLCLASH_HOTSPOT_DNS")
	upstream, err := netip.ParseAddrPort(dnsAddress)
	if err != nil || !upstream.Addr().IsLoopback() {
		t.Fatal("explicit loopback DNS required")
	}
	var queries atomic.Uint64
	handler := D.HandlerFunc(func(w D.ResponseWriter, r *D.Msg) {
		queries.Add(1)
		if len(r.Question) == 1 && r.Question[0].Qtype == D.TypeAAAA {
			a := new(D.Msg)
			a.SetReply(r)
			_ = w.WriteMsg(a)
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		client := D.Client{Net: "udp", Timeout: 8 * time.Second}
		a, _, err := client.ExchangeContext(ctx, r, dnsAddress)
		if err == nil && a.Truncated {
			client.Net = "tcp"
			a, _, err = client.ExchangeContext(ctx, r, dnsAddress)
		}
		if err != nil {
			a = new(D.Msg)
			a.SetRcode(r, D.RcodeServerFailure)
		}
		_ = w.WriteMsg(a)
	})
	m := New(func() Environment {
		return Environment{Running: true, DNSReady: true, TunDevice: device, TunAddress: address}
	}, handler)
	defer m.Close()
	s := m.SetEnabled(true)
	if !s.Active {
		t.Fatalf("enable: %+v", s)
	}
	executable, _ := os.Executable()
	statusPath := filepath.Join(filepath.Dir(executable), "manual-session.json")
	writeStatus := func(s Status) {
		b, _ := json.Marshal(struct {
			Status
			PID     int    `json:"pid"`
			Queries uint64 `json:"queries"`
		}{s, os.Getpid(), queries.Load()})
		_ = os.WriteFile(statusPath, b, 0644)
	}
	writeStatus(s)
	t.Logf("ACTIVE gateway=%s interface=%s tun=%s pid=%d", s.Address, s.Interface, s.TunDevice, os.Getpid())
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	select {
	case <-ctx.Done():
	case <-time.After(10 * time.Minute):
	}
	s = m.SetEnabled(false)
	writeStatus(s)
	if s.Active || s.Error != "" {
		t.Fatalf("cleanup: %+v", s)
	}
	t.Log("REMOVED temporary hotspot rules; installed proxy untouched")
}
