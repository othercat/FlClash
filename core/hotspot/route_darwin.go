package hotspot

import (
	"errors"
	"net"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

func defaultRouteInterface() (string, error) {
	rib, err := route.FetchRIB(unix.AF_INET, route.RIBTypeRoute, 0)
	if err != nil {
		return "", err
	}
	messages, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return "", err
	}
	index, err := defaultRouteIndex(messages)
	if err != nil {
		return "", err
	}
	iface, err := net.InterfaceByIndex(index)
	if err != nil {
		return "", err
	}
	return iface.Name, nil
}

func defaultRouteIndex(messages []route.Message) (int, error) {
	index := 0
	for _, message := range messages {
		r, ok := message.(*route.RouteMessage)
		// Err describes route-socket replies, not FetchRIB dump entries; the
		// latter can have nonzero data there even on a valid global default.
		if !ok || r.Index <= 0 || r.Flags&unix.RTF_UP == 0 || r.Flags&(unix.RTF_IFSCOPE|unix.RTF_REJECT|unix.RTF_BLACKHOLE|unix.RTF_HOST) != 0 || len(r.Addrs) <= unix.RTAX_NETMASK {
			continue
		}
		destination, ok := r.Addrs[unix.RTAX_DST].(*route.Inet4Addr)
		if !ok || destination.IP != [4]byte{} {
			continue
		}
		mask, ok := r.Addrs[unix.RTAX_NETMASK].(*route.Inet4Addr)
		if r.Addrs[unix.RTAX_NETMASK] != nil && (!ok || mask.IP != [4]byte{}) {
			continue
		}
		if index != 0 && index != r.Index {
			return 0, errors.New("ambiguous native default route")
		}
		index = r.Index
	}
	if index == 0 {
		return 0, errors.New("no native IPv4 default route")
	}
	return index, nil
}
