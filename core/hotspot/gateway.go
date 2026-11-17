// Package hotspot owns the opt-in macOS Internet Sharing gateway.
package hotspot

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/log"
	D "github.com/miekg/dns"
)

type Environment struct {
	Running       bool
	TunDevice     string
	TunAddress    netip.Addr
	DNSReady      bool
	RouterAddress string
	Tun6Address   netip.Addr
	IPv6Ready     bool
}

type Status struct {
	Supported       bool           `json:"supported"`
	Enabled         bool           `json:"enabled"`
	Active          bool           `json:"active"`
	Interface       string         `json:"interface,omitempty"`
	Address         string         `json:"address,omitempty"`
	Network         string         `json:"network,omitempty"`
	TunDevice       string         `json:"tunDevice,omitempty"`
	Error           string         `json:"error,omitempty"`
	SelectedAddress string         `json:"selectedAddress,omitempty"`
	Interfaces      []LANInterface `json:"interfaces,omitempty"`
	IPv6Gateway     string         `json:"ipv6Gateway,omitempty"`
	IPv6DNS         string         `json:"ipv6DNS,omitempty"`
}

type link struct {
	Interface     string
	Address       netip.Addr
	Network       netip.Prefix
	IPv6          string
	IPv6Networks  string
	HostAddresses string
	DNSInterfaces string
	TunDevice     string
	TunAddress    netip.Addr
	Router        bool
	StateLabel    string
	Tun6Address   netip.Addr
}

var errPlatformTemporary = errors.New("sharing platform temporarily unavailable")

func (l link) sameDNSEndpoints(other link) bool {
	return l.Interface == other.Interface && l.Address == other.Address && l.Network == other.Network && l.IPv6 == other.IPv6 && l.IPv6Networks == other.IPv6Networks && l.DNSInterfaces == other.DNSInterfaces
}

func (l link) sameForwardingPath(other link) bool {
	return l.sameDNSEndpoints(other) && l.TunDevice == other.TunDevice && l.TunAddress == other.TunAddress && l.Tun6Address == other.Tun6Address
}

type platform interface {
	detect(Environment) (link, error)
	install(link, int) error
	maintain(link, int) error
	remove() error
}

type Manager struct {
	mu              sync.Mutex
	platform        platform
	environment     func() Environment
	handler         D.Handler
	status          Status
	link            link
	dns             *dnsListener
	cancel          context.CancelFunc
	wake            chan struct{}
	dirty           bool
	suspended       bool
	router          bool
	selectedAddress string
}

func New(environment func() Environment, handler D.Handler) *Manager {
	p := newPlatform()
	return &Manager{platform: p, environment: environment, handler: handler, status: Status{Supported: p != nil}}
}

func NewRouter(environment func() Environment, handler D.Handler) *Manager {
	p := newRouterPlatform()
	return &Manager{platform: p, environment: environment, handler: handler, router: true, status: Status{Supported: p != nil}}
}

func (m *Manager) Status() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.statusLocked()
}

func (m *Manager) statusLocked() Status {
	s := m.status
	if m.router {
		s.SelectedAddress = m.selectedAddress
		s.Interfaces, _ = routerInterfaces()
	}
	return s
}

// Changing a live gateway address would strand configured clients. Require an
// explicit disable before selecting another interface; never change the host IP.
func (m *Manager) SetRouter(enabled bool, address string) Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.router {
		return Status{Error: "unsupported"}
	}
	if enabled && m.status.Enabled && address != m.selectedAddress {
		s := m.statusLocked()
		s.Error = "disableBeforeChanging"
		return s
	}
	if enabled {
		m.selectedAddress = address
	}
	m.setEnabledLocked(enabled)
	return m.statusLocked()
}

// SetEnabled never changes the host TUN, system DNS, or Internet Sharing.
// Enabled is the user's intent; Active describes the installed forwarding path.
func (m *Manager) SetEnabled(enabled bool) Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.setEnabledLocked(enabled)
}

func (m *Manager) setEnabledLocked(enabled bool) Status {
	if !enabled {
		m.stopLocked()
		return m.status
	}
	if m.status.Enabled {
		m.syncLocked()
		m.wakeLocked()
		return m.status
	}
	if m.platform == nil {
		m.status.Error = "unsupported"
		return m.status
	}
	m.status.Error = ""
	m.status.Enabled = true
	m.syncLocked()
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.wake = make(chan struct{}, 1)
	go m.monitor(ctx, m.wake)
	return m.status
}

func (m *Manager) checkIntervalLocked() time.Duration {
	if m.status.Active && !m.suspended {
		return 5 * time.Second
	}
	return time.Minute
}

func (m *Manager) wakeLocked() {
	if m.wake != nil {
		select {
		case m.wake <- struct{}{}:
		default:
		}
	}
}

func (m *Manager) monitor(ctx context.Context, wake <-chan struct{}) {
	m.mu.Lock()
	interval := m.checkIntervalLocked()
	m.mu.Unlock()
	timer := time.NewTimer(interval)
	defer timer.Stop()
	for {
		check := false
		select {
		case <-ctx.Done():
			return
		case <-wake:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		case <-timer.C:
			check = true
		}
		m.mu.Lock()
		if ctx.Err() != nil {
			m.mu.Unlock()
			return
		}
		if check && m.status.Enabled {
			m.syncLocked()
		}
		interval = m.checkIntervalLocked()
		m.mu.Unlock()
		timer.Reset(interval)
	}
}

func (m *Manager) Close() { m.SetEnabled(false) }

// Suspend removes forwarding before listeners stop without losing the user's
// choice. The monitor must not reinstall against the old, not-yet-closed TUN.
func (m *Manager) Suspend() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.suspended = true
	m.deactivateLocked()
	if m.status.Enabled && !m.dirty {
		m.status.Error = "tunRequired"
	}
	m.wakeLocked()
}

func (m *Manager) Resume() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.suspended = false
	m.syncLocked()
	m.wakeLocked()
}

func (m *Manager) stopLocked() {
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.wake = nil
	m.status.Enabled = false
	m.suspended = false
	m.deactivateLocked()
	if !m.status.Active {
		m.status.Error = ""
	}
}

func (m *Manager) deactivateLocked() {
	// Leave the DNS service alive if removing a redirect fails. A subsequent
	// disable retries removal rather than stranding clients at a closed port.
	if m.platform != nil && (m.status.Active || m.dns != nil) {
		if err := m.platform.remove(); err != nil {
			m.dirty = true
			m.status.Error = "cleanup: " + err.Error()
			return
		}
	}
	if m.dns != nil {
		m.dns.close()
		m.dns = nil
	}
	m.status.Active = false
	m.link = link{}
	m.dirty = false
}

func (m *Manager) syncLocked() {
	if !m.status.Enabled || m.suspended {
		return
	}
	if m.dirty {
		m.deactivateLocked()
		if m.dirty {
			return
		}
	}
	env := m.environment()
	if m.router {
		env.RouterAddress = m.selectedAddress
	}
	if !env.Running || !env.DNSReady || !env.TunAddress.Is4() || !tunName.MatchString(env.TunDevice) {
		m.deactivateLocked()
		m.status.Error = "tunRequired"
		return
	}
	l, err := m.platform.detect(env)
	if err != nil {
		if m.status.Active && errors.Is(err, errPlatformTemporary) {
			m.setRecoveryError(err)
			return
		}
		m.deactivateLocked()
		m.status.Error = err.Error()
		return
	}
	if m.status.Active && l.sameForwardingPath(m.link) {
		// Repair external forwarding/PF resets without closing DNS, changing
		// its port or retiring existing hotspot/host connections. A failed
		// health check is visible and retried; the last installed DNS stays up.
		// Local/VPN addresses can change on the same path. The platform
		// refreshes exclusions through the same bounded recovery mechanism.
		err := m.platform.maintain(l, m.dns.port)
		m.setRecoveryError(err)
		if err == nil {
			m.link = l
			m.status.TunDevice = l.TunDevice
		}
		return
	}
	if m.status.Active {
		m.deactivateLocked()
		if m.dns != nil {
			return
		}
	}
	if m.dns == nil {
		m.link = l
		m.dns, err = listenDNS(l, m.handler)
		if err != nil {
			m.status.Error = "dns: " + err.Error()
			return
		}
	}
	if err = m.platform.install(l, m.dns.port); err != nil {
		m.deactivateLocked()
		m.status.Error = "pf: " + err.Error()
		return
	}
	m.dirty = false
	m.link = l
	m.status = Status{Supported: true, Enabled: true, Active: true, Interface: l.Interface, Address: l.Address.String(), Network: l.Network.String(), TunDevice: l.TunDevice}
	if m.router {
		m.status.IPv6Gateway, m.status.IPv6DNS = l.routerIPv6Addresses()
	}
}

func (m *Manager) setRecoveryError(err error) {
	if err == nil {
		m.status.Error = ""
		return
	}
	message := "recovery: " + err.Error()
	if m.status.Error != message {
		tag := "Hotspot"
		if m.router {
			tag = "SoftRouter"
		}
		log.Warnln("[%s] %s", tag, message)
	}
	m.status.Error = message
}

var (
	bridgeName = regexp.MustCompile(`^bridge[0-9]+$`)
	tunName    = regexp.MustCompile(`^utun[0-9]+$`)
	memberName = regexp.MustCompile(`^(ap|en)[0-9]+$`)
)

func rules(l link, port int) (string, error) {
	validInterface := bridgeName.MatchString(l.Interface)
	if l.Router {
		validInterface = lanName.MatchString(l.Interface) && privateLANPrefix(l.Network) && routerLabel.MatchString(l.StateLabel)
	}
	if !validInterface || !tunName.MatchString(l.TunDevice) || !l.Address.Is4() || !l.TunAddress.Is4() || !l.Network.IsValid() || !l.Network.Addr().Is4() || !l.Network.Contains(l.Address) || port < 1024 || port > 65535 {
		return "", errors.New("invalid gateway link")
	}
	if l.Router {
		return routerRules(l, port)
	}
	// No rule matches a host-originated packet. Redirect to the hotspot address,
	// not loopback, avoiding platform-specific translated-loopback semantics.
	var local6 []string
	for _, raw := range strings.Fields(l.IPv6Networks) {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil || !prefix.Addr().Is6() {
			return "", errors.New("invalid hotspot IPv6 network")
		}
		local6 = append(local6, prefix.Masked().String())
	}
	extra := ""
	if len(local6) > 0 {
		extra = ", " + strings.Join(local6, ", ")
	}
	interfaces := []string{l.Interface}
	for _, name := range strings.Fields(l.DNSInterfaces) {
		if name == l.Interface {
			continue
		}
		if !memberName.MatchString(name) {
			return "", errors.New("invalid hotspot member")
		}
		interfaces = append(interfaces, name)
	}
	dnsInterfaces := l.Interface
	if len(interfaces) > 1 {
		dnsInterfaces = "{ " + strings.Join(interfaces, ", ") + " }"
	}
	var dns6Addresses []netip.Addr
	for _, raw := range strings.Fields(l.IPv6) {
		ip, err := netip.ParseAddr(raw)
		if err != nil || !ip.Is6() || ip.Is4In6() || ip.IsUnspecified() || ip.IsMulticast() || (ip.Zone() != "" && ip.Zone() != l.Interface) {
			return "", errors.New("invalid hotspot IPv6 listener")
		}
		dns6Addresses = append(dns6Addresses, ip.WithZone(""))
	}
	var dns6 strings.Builder
	if len(dns6Addresses) > 0 {
		// Darwin's dynamic (interface) tables exclude link-local addresses.
		// Match each listener explicitly and prefer a ULA/global backend so
		// bridged packets do not depend on a link-local socket's scope ID.
		target := dns6Addresses[0]
		for _, ip := range dns6Addresses {
			if !ip.IsLinkLocalUnicast() {
				target = ip
				break
			}
		}
		for _, ip := range dns6Addresses {
			fmt.Fprintf(&dns6, "rdr pass on %s inet6 proto { tcp udp } from any to %s port 53 -> %s port %d\n", dnsInterfaces, ip, target, port)
		}
	}
	return fmt.Sprintf(`table <flclash_hotspot_local> { self, %[2]s, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4, fe80::/10, ff00::/8%[7]s }
rdr pass on %[8]s inet proto { tcp udp } from %[2]s to (%[1]s) port 53 -> %[6]s port %[3]d
%[9]spass in quick on %[1]s route-to (%[4]s %[5]s) inet from %[2]s to ! <flclash_hotspot_local> flags any keep state
block return in quick on %[1]s inet6 from any to ! <flclash_hotspot_local>
`, l.Interface, l.Network.Masked(), port, l.TunDevice, l.TunAddress, l.Address, extra, dnsInterfaces, dns6.String()), nil
}

type dnsListener struct {
	port    int
	servers []*D.Server
}

func listenDNS(l link, handler D.Handler) (*dnsListener, error) {
	s := &dnsListener{}
	if l.Router {
		// Fixed backend across mode toggles/core restarts: old DNS translation
		// states cannot strand clients at an ephemeral closed port. Unlike a
		// hotspot, a shared LAN must never be flushed by source subnet.
		s.port = 1054
	}
	guarded := D.HandlerFunc(func(w D.ResponseWriter, r *D.Msg) {
		if !l.allowsDNSPeer(w.RemoteAddr().String()) {
			a := new(D.Msg)
			a.SetRcode(r, D.RcodeRefused)
			_ = w.WriteMsg(a)
			return
		}
		// A LAN/TUN without a usable IPv6 data path must not advertise AAAA
		// answers that clients would send through a different IPv6 gateway.
		if l.Router && !l.Tun6Address.IsValid() && len(r.Question) == 1 && r.Question[0].Qtype == D.TypeAAAA {
			a := new(D.Msg)
			a.SetReply(r)
			a.RecursionAvailable = true
			_ = w.WriteMsg(a)
			return
		}
		handler.ServeDNS(w, r)
	})
	// Reserve one high port only on the hotspot addresses before installing
	// redirects. Never compete for system port 53 or expose upstream listeners.
	type endpoint struct{ network, host string }
	endpoints := []endpoint{{"tcp4", l.Address.String()}, {"udp4", l.Address.String()}}
	for _, host := range strings.Fields(l.IPv6) {
		endpoints = append(endpoints, endpoint{"tcp6", host}, endpoint{"udp6", host})
	}
	for _, endpoint := range endpoints {
		network, host := endpoint.network, endpoint.host
		address := net.JoinHostPort(host, fmt.Sprint(s.port))
		server := &D.Server{Handler: guarded, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, MaxTCPQueries: 64}
		if strings.HasPrefix(network, "tcp") {
			l, err := net.Listen(network, address)
			if err != nil {
				s.close()
				return nil, err
			}
			server.Listener = l
			if s.port == 0 {
				s.port = l.Addr().(*net.TCPAddr).Port
			}
		} else {
			p, err := net.ListenPacket(network, address)
			if err != nil {
				s.close()
				return nil, err
			}
			server.PacketConn = p
		}
		s.servers = append(s.servers, server)
	}
	for _, server := range s.servers {
		go func(server *D.Server) { _ = server.ActivateAndServe() }(server)
	}
	return s, nil
}

func (l link) allowsDNSPeer(remote string) bool {
	peer, err := netip.ParseAddrPort(remote)
	if err != nil {
		return false
	}
	ip := peer.Addr().Unmap()
	if ip.Is4() {
		return l.Network.Contains(ip)
	}
	if ip.IsLinkLocalUnicast() && ip.Zone() != l.Interface {
		found := false
		for _, name := range strings.Fields(l.DNSInterfaces) {
			if name == ip.Zone() {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	for _, raw := range strings.Fields(l.IPv6Networks) {
		prefix, err := netip.ParsePrefix(raw)
		if err == nil && prefix.Contains(ip.WithZone("")) {
			return true
		}
	}
	return false
}

func (s *dnsListener) close() {
	for _, server := range s.servers {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		_ = server.ShutdownContext(ctx)
		cancel()
		if server.Listener != nil {
			_ = server.Listener.Close()
		}
		if server.PacketConn != nil {
			_ = server.PacketConn.Close()
		}
	}
}
