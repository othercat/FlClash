package main

import (
	"context"
	"core/hotspot"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/listener"
	D "github.com/miekg/dns"
)

func gatewayEnvironment() hotspot.Environment {
	runLock.Lock()
	defer runLock.Unlock()
	if !isRunning || currentConfig == nil {
		return hotspot.Environment{}
	}
	tun := listener.GetTunConf()
	env := hotspot.Environment{Running: tun.Enable && tun.AutoRoute, DNSReady: currentConfig.DNS.Enable && resolver.DefaultService != nil, TunDevice: tun.Device}
	if len(tun.Inet4Address) > 0 {
		env.TunAddress = tun.Inet4Address[0].Addr()
	}
	if len(tun.Inet6Address) > 0 {
		env.Tun6Address = tun.Inet6Address[0].Addr()
	}
	env.IPv6Ready = currentConfig.General != nil && currentConfig.General.IPv6 && currentConfig.DNS.IPv6
	return env
}

var hotspotGateway = hotspot.New(gatewayEnvironment, D.HandlerFunc(serveHotspotDNS))
var softRouterGateway = hotspot.NewRouter(gatewayEnvironment, D.HandlerFunc(serveSoftRouterDNS))

// Serialize listener transitions without holding runLock while a gateway reads
// its environment (gateway lock -> runLock is the established lock order).
var gatewayLifecycleMu sync.Mutex

func serveHotspotDNS(w D.ResponseWriter, r *D.Msg) {
	// The hotspot currently has an IPv4 data path. Do not advertise an IPv6
	// answer that Internet Sharing could send around that path.
	if len(r.Question) == 1 && r.Question[0].Qtype == D.TypeAAAA {
		answer := new(D.Msg)
		answer.SetReply(r)
		answer.RecursionAvailable = true
		_ = w.WriteMsg(answer)
		return
	}
	serveSoftRouterDNS(w, r)
}

func serveSoftRouterDNS(w D.ResponseWriter, r *D.Msg) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	answer, err := resolver.ServeMsg(ctx, r)
	if err != nil {
		answer = new(D.Msg)
		answer.SetRcode(r, D.RcodeServerFailure)
	}
	answer.Compress = true
	_ = w.WriteMsg(answer)
}
