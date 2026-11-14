package routeiface

import (
	"errors"
	"net/netip"

	"golang.org/x/sys/windows"
)

func routeInterfaceIndex(destination netip.Addr) (int, error) {
	var address windows.Sockaddr
	destination = destination.Unmap()
	switch {
	case destination.Is4():
		address = &windows.SockaddrInet4{Addr: destination.As4()}
	case destination.Is6():
		address = &windows.SockaddrInet6{Addr: destination.As16()}
	default:
		return 0, errors.New("invalid route destination")
	}
	var index uint32
	if err := windows.GetBestInterfaceEx(address, &index); err != nil {
		return 0, err
	}
	if index == 0 {
		return 0, errors.New("route has no interface")
	}
	return int(index), nil
}
