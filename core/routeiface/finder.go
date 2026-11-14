//go:build darwin || windows

// Package routeiface makes TUN interface detection honor destination routes.
package routeiface

import (
	"net/netip"

	"github.com/metacubex/sing/common/control"
)

type finder struct {
	control.InterfaceFinder
	lookup func(netip.Addr) (int, error)
}

// New keeps the existing interface inventory and asks the OS for the egress
// interface. In particular, VPN routes need not share the VPN adapter's subnet.
// A route back to our own TUN is returned unchanged: mihomo's existing TUN
// detector must reject it and fall back to the physical default interface.
func New(base control.InterfaceFinder) control.InterfaceFinder {
	return &finder{InterfaceFinder: base, lookup: routeInterfaceIndex}
}

func (f *finder) ByAddr(destination netip.Addr) (*control.Interface, error) {
	destination = destination.Unmap()
	if destination.IsGlobalUnicast() {
		if index, err := f.lookup(destination); err == nil && index > 0 {
			if iface, err := f.ByIndex(index); err == nil && iface != nil {
				return iface, nil
			}
		}
	}
	// Preserve upstream behavior for unspecified addresses, local scopes, missing
	// adapters and lookup failures. Unspecified addresses drive its loop guard.
	return f.InterfaceFinder.ByAddr(destination)
}
