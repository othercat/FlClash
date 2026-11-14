package routeiface

import (
	"errors"
	"net/netip"
	"os"
	"sync/atomic"
	"time"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

var routeSequence atomic.Uint32

func routeInterfaceIndex(destination netip.Addr) (int, error) {
	var address route.Addr
	destination = destination.Unmap()
	switch {
	case destination.Is4():
		address = &route.Inet4Addr{IP: destination.As4()}
	case destination.Is6():
		address = &route.Inet6Addr{IP: destination.As16()}
	default:
		return 0, errors.New("invalid route destination")
	}

	fd, err := unix.Socket(unix.AF_ROUTE, unix.SOCK_RAW, unix.AF_UNSPEC)
	if err != nil {
		return 0, err
	}
	defer unix.Close(fd)
	unix.CloseOnExec(fd)
	addresses := make([]route.Addr, unix.RTAX_MAX)
	addresses[unix.RTAX_DST] = address
	addresses[unix.RTAX_IFP] = &route.LinkAddr{}
	request := &route.RouteMessage{
		Version: unix.RTM_VERSION,
		Type:    unix.RTM_GET,
		ID:      uintptr(os.Getpid()),
		Seq:     int(routeSequence.Add(1) & 0x7fffffff),
		Addrs:   addresses,
	}
	message, err := request.Marshal()
	if err != nil {
		return 0, err
	}
	if _, err := unix.Write(fd, message); err != nil {
		return 0, err
	}
	buffer := make([]byte, 8192)
	deadline := time.Now().Add(200 * time.Millisecond)
	// Routing sockets also receive notifications. Match each concurrent request
	// by its unique sequence and bound the total wait, not just each read.
	for i := 0; i < 8; i++ {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return 0, errors.New("route lookup timed out")
		}
		timeout := unix.NsecToTimeval(remaining.Nanoseconds())
		if err := unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &timeout); err != nil {
			return 0, err
		}
		n, err := unix.Read(fd, buffer)
		if err != nil {
			return 0, err
		}
		messages, err := route.ParseRIB(route.RIBTypeRoute, buffer[:n])
		if err != nil {
			return 0, err
		}
		for _, message := range messages {
			response, ok := message.(*route.RouteMessage)
			if !ok || response.Type != unix.RTM_GET || response.ID != request.ID || response.Seq != request.Seq {
				continue
			}
			if response.Err != nil {
				return 0, response.Err
			}
			if response.Index > 0 {
				return response.Index, nil
			}
			return 0, errors.New("route has no interface")
		}
	}
	return 0, errors.New("route lookup received no matching response")
}
