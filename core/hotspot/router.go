package hotspot

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"regexp"
	"sort"
	"strings"
)

type LANInterface struct {
	Name         string   `json:"name"`
	Address      string   `json:"address"`
	Network      string   `json:"network"`
	IPv6         []string `json:"ipv6"`
	IPv6Networks []string `json:"ipv6Networks"`
}

var lanName = regexp.MustCompile(`^en[0-9]+$`)
var routerLabel = regexp.MustCompile(`^flclash-router-[0-9]+$`)

func privateLANPrefix(p netip.Prefix) bool {
	if !p.IsValid() || !p.Addr().Is4() || p.Bits() > 30 {
		return false
	}
	for _, block := range []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("172.16.0.0/12"), netip.MustParsePrefix("192.168.0.0/16")} {
		if p.Bits() >= block.Bits() && block.Contains(p.Masked().Addr()) {
			return true
		}
	}
	return false
}

func routerInterfaces() ([]LANInterface, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var choices []LANInterface
	for _, iface := range interfaces {
		if !lanName.MatchString(iface.Name) || iface.Flags&(net.FlagUp|net.FlagRunning) != net.FlagUp|net.FlagRunning || iface.Flags&(net.FlagLoopback|net.FlagPointToPoint) != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		var ipv6, networks6 []string
		seen := map[string]bool{}
		for _, a := range addresses {
			p, err := netip.ParsePrefix(a.String())
			if err != nil || !p.Addr().Is6() || p.Addr().Is4In6() || p.Addr().IsLoopback() || p.Addr().IsMulticast() || p.Addr().IsUnspecified() || p.Bits() < 48 || p.Bits() > 126 {
				continue
			}
			ip := p.Addr()
			if ip.IsLinkLocalUnicast() {
				ip = ip.WithZone(iface.Name)
			}
			ipv6 = append(ipv6, ip.String())
			network := p.Masked().String()
			if !seen[network] {
				networks6 = append(networks6, network)
				seen[network] = true
			}
		}
		for _, a := range addresses {
			p, err := netip.ParsePrefix(a.String())
			if err == nil && privateLANPrefix(p) {
				choices = append(choices, LANInterface{Name: iface.Name, Address: p.Addr().String(), Network: p.Masked().String(), IPv6: ipv6, IPv6Networks: networks6})
			}
		}
	}
	sort.Slice(choices, func(i, j int) bool {
		if choices[i].Name != choices[j].Name {
			return choices[i].Name < choices[j].Name
		}
		return choices[i].Address < choices[j].Address
	})
	return choices, nil
}

func selectRouterLink(env Environment, choices []LANInterface, preferred string) (link, error) {
	if env.RouterAddress == "" && preferred == "" && len(choices) != 1 {
		return link{}, errors.New("lanRequired")
	}
	for _, c := range choices {
		if env.RouterAddress != "" && c.Address != env.RouterAddress {
			continue
		}
		if env.RouterAddress == "" && preferred != "" && c.Name != preferred {
			continue
		}
		address, err := netip.ParseAddr(c.Address)
		network, netErr := netip.ParsePrefix(c.Network)
		if err != nil || netErr != nil || !lanName.MatchString(c.Name) || !privateLANPrefix(network) || !network.Contains(address) {
			continue
		}
		l := link{Interface: c.Name, Address: address, Network: network, TunDevice: env.TunDevice, TunAddress: env.TunAddress, Tun6Address: env.Tun6Address, Router: true, IPv6: strings.Join(c.IPv6, " "), IPv6Networks: strings.Join(c.IPv6Networks, " ")}
		gateway6, dns6 := l.routerIPv6Addresses()
		if !env.IPv6Ready || !env.Tun6Address.Is6() || gateway6 == "" || dns6 == "" {
			l.disableIPv6()
		}
		return l, nil
	}
	return link{}, errors.New("lanRequired")
}

func (l *link) disableIPv6() {
	l.IPv6, l.IPv6Networks = "", ""
	l.Tun6Address = netip.Addr{}
}

func (l link) routerIPv6Addresses() (gateway, dns string) {
	for _, raw := range strings.Fields(l.IPv6) {
		ip, err := netip.ParseAddr(raw)
		if err != nil || !ip.Is6() || ip.Is4In6() || ip.IsMulticast() || ip.IsUnspecified() {
			continue
		}
		if ip.IsLinkLocalUnicast() {
			gateway = ip.WithZone("").String()
		} else if dns == "" || ip.IsPrivate() {
			dns = ip.WithZone("").String()
		}
	}
	if gateway == "" {
		gateway = dns
	}
	return
}

// route-to consumes each direction at the inbound PF hook, before the kernel
// forwarding gates (XNU ip6_input.c). Explicit return rules avoid changing the
// host's global IPv6 router/RA behaviour and never divert packets to host IPs.
func routerRules(l link, port int) (string, error) {
	if !l.Tun6Address.IsValid() && l.IPv6 == "" && l.IPv6Networks == "" {
		return fmt.Sprintf(`table <flclash_router_local> { self, %[2]s, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
table <flclash_router_clients> { %[2]s, !self }
rdr pass on %[1]s inet proto { tcp udp } from <flclash_router_clients> to %[3]s port 53 -> %[3]s port %[4]d
pass in quick on %[1]s route-to (%[5]s %[6]s) inet from <flclash_router_clients> to ! <flclash_router_local> no state label "%[7]s"
pass in quick on %[5]s route-to %[1]s inet to <flclash_router_clients> no state label "%[7]s"
`, l.Interface, l.Network.Masked(), l.Address, port, l.TunDevice, l.TunAddress, l.StateLabel), nil
	}
	if !l.Tun6Address.Is6() || l.Tun6Address.Is4In6() || l.Tun6Address.IsUnspecified() || l.Tun6Address.IsMulticast() {
		return "", errors.New("IPv6 TUN is required")
	}
	_, backend := l.routerIPv6Addresses()
	if backend == "" {
		return "", errors.New("LAN IPv6 is required")
	}
	var networks []string
	for _, raw := range strings.Fields(l.IPv6Networks) {
		p, err := netip.ParsePrefix(raw)
		if err != nil || !p.Addr().Is6() || p.Addr().Is4In6() || p.Bits() < 48 || p.Bits() > 126 || p.Addr().IsMulticast() {
			return "", errors.New("invalid LAN IPv6 network")
		}
		networks = append(networks, p.Masked().String())
	}
	if len(networks) == 0 {
		return "", errors.New("LAN IPv6 prefix is required")
	}
	networksText := strings.Join(networks, ", ")
	var dns6 strings.Builder
	for _, raw := range strings.Fields(l.IPv6) {
		ip, err := netip.ParseAddr(raw)
		if err != nil || !ip.Is6() || ip.Is4In6() || ip.IsMulticast() || ip.IsUnspecified() || (ip.Zone() != "" && ip.Zone() != l.Interface) {
			return "", errors.New("invalid LAN IPv6 listener")
		}
		fmt.Fprintf(&dns6, "rdr pass on %s inet6 proto { tcp udp } from <flclash_router_clients> to %s port 53 -> %s port %d\n", l.Interface, ip.WithZone(""), backend, port)
	}
	return fmt.Sprintf(`table <flclash_router_local> { self, %[2]s, %[8]s, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4, fe80::/10, ff00::/8 }
table <flclash_router_clients> { %[2]s, %[8]s, !self }
rdr pass on %[1]s inet proto { tcp udp } from <flclash_router_clients> to %[6]s port 53 -> %[6]s port %[3]d
%[9]spass in quick on %[1]s route-to (%[4]s %[5]s) inet from <flclash_router_clients> to ! <flclash_router_local> no state label "%[7]s"
pass in quick on %[1]s route-to (%[4]s %[10]s) inet6 from <flclash_router_clients> to ! <flclash_router_local> no state label "%[7]s"
pass in quick on %[4]s route-to %[1]s inet to <flclash_router_clients> no state label "%[7]s"
pass in quick on %[4]s route-to %[1]s inet6 to <flclash_router_clients> no state label "%[7]s"
`, l.Interface, l.Network.Masked(), port, l.TunDevice, l.TunAddress, l.Address, l.StateLabel, networksText, dns6.String(), l.Tun6Address), nil
}
