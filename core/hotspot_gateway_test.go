package main

import (
	"context"
	"net"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
)

type routerDNSService struct{ calls int }

func (s *routerDNSService) ServeMsg(_ context.Context, q *D.Msg) (*D.Msg, error) {
	s.calls++
	a := new(D.Msg)
	a.SetReply(q)
	a.RecursionAvailable = true
	a.Answer = []D.RR{&D.AAAA{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeAAAA, Class: D.ClassINET, Ttl: 60}, AAAA: net.ParseIP("2001:db8::123")}}
	return a, nil
}

func TestSoftRouterUsesNativeAAAAResolver(t *testing.T) {
	old := resolver.DefaultService
	service := &routerDNSService{}
	resolver.DefaultService = service
	defer func() { resolver.DefaultService = old }()
	q := new(D.Msg)
	q.SetQuestion("example.com.", D.TypeAAAA)
	w := &hotspotDNSRecorder{}
	serveSoftRouterDNS(w, q)
	if service.calls != 1 || w.answer == nil || len(w.answer.Answer) != 1 || w.answer.Answer[0].Header().Rrtype != D.TypeAAAA || !w.answer.RecursionAvailable {
		t.Fatal("soft router suppressed/replaced native AAAA")
	}
	w = &hotspotDNSRecorder{}
	serveHotspotDNS(w, q)
	if service.calls != 1 || len(w.answer.Answer) != 0 {
		t.Fatal("existing IPv4 hotspot DNS changed")
	}
}

type hotspotDNSRecorder struct {
	D.ResponseWriter
	answer *D.Msg
}

func (w *hotspotDNSRecorder) WriteMsg(answer *D.Msg) error {
	w.answer = answer.Copy()
	return nil
}

func TestHotspotAAAAReplyAdvertisesRecursion(t *testing.T) {
	request := new(D.Msg)
	request.SetQuestion("apps.apple.com.", D.TypeAAAA)
	w := &hotspotDNSRecorder{}
	serveHotspotDNS(w, request)
	answer := w.answer
	if answer == nil || !answer.Response || answer.Id != request.Id || answer.Rcode != D.RcodeSuccess || !answer.RecursionDesired || !answer.RecursionAvailable || len(answer.Answer) != 0 {
		t.Fatalf("invalid recursive NODATA reply: %+v", answer)
	}
}
