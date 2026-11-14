//go:build darwin || windows

package routeiface

import (
	"errors"
	"net"
	"net/netip"
	"testing"

	"github.com/metacubex/sing/common/control"
)

type testInventory struct {
	control.InterfaceFinder
	interfaces map[int]*control.Interface
	fallback   *control.Interface
}

func (f *testInventory) ByIndex(index int) (*control.Interface, error) {
	if iface := f.interfaces[index]; iface != nil {
		return iface, nil
	}
	return nil, errors.New("interface removed")
}

func (f *testInventory) ByAddr(netip.Addr) (*control.Interface, error) {
	return f.fallback, nil
}

func TestDestinationRoutes(t *testing.T) {
	base := &testInventory{
		interfaces: map[int]*control.Interface{
			1: {Index: 1, Name: "physical"},
			2: {Index: 2, Name: "vpn"},
			3: {Index: 3, Name: "own-tun"},
		},
		fallback: &control.Interface{Name: "upstream"},
	}
	for _, tc := range []struct {
		name        string
		destination string
		index       int
		lookupError bool
		want        string
		wantLookup  bool
	}{
		{"vpn route outside adapter subnet", "10.12.166.207", 2, false, "vpn", true},
		{"aTrust synthetic route", "198.18.0.42", 2, false, "vpn", true},
		{"physical host route", "1.1.1.1", 1, false, "physical", true},
		{"own TUN left for upstream loop guard", "8.8.8.8", 3, false, "own-tun", true},
		{"IPv6 VPN route", "fd00::42", 2, false, "vpn", true},
		{"mapped IPv4", "::ffff:10.12.166.207", 2, false, "vpn", true},
		{"lookup failure", "1.1.1.1", 1, true, "upstream", true},
		{"removed interface", "10.12.166.207", 99, false, "upstream", true},
		{"no interface", "1.1.1.1", 0, false, "upstream", true},
		{"IPv4 fallback for loop guard", "0.0.0.0", 3, false, "upstream", false},
		{"IPv6 fallback for loop guard", "::", 3, false, "upstream", false},
		{"loopback", "127.0.0.1", 3, false, "upstream", false},
		{"link local", "fe80::1", 3, false, "upstream", false},
		{"multicast", "224.0.0.1", 3, false, "upstream", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			f := &finder{InterfaceFinder: base, lookup: func(destination netip.Addr) (int, error) {
				called = true
				if destination.Is4In6() {
					t.Fatal("mapped IPv4 was not normalized")
				}
				if tc.lookupError {
					return 0, errors.New("route lookup failed")
				}
				return tc.index, nil
			}}
			got, err := f.ByAddr(netip.MustParseAddr(tc.destination))
			if err != nil || got.Name != tc.want || called != tc.wantLookup {
				t.Fatalf("got %v, %v, lookup=%v; want %s, lookup=%v", got, err, called, tc.want, tc.wantLookup)
			}
		})
	}
}

func TestRouteChangesAreNotCached(t *testing.T) {
	base := &testInventory{interfaces: map[int]*control.Interface{
		1: {Index: 1, Name: "physical"},
		2: {Index: 2, Name: "vpn"},
	}}
	index := 1
	f := &finder{InterfaceFinder: base, lookup: func(netip.Addr) (int, error) { return index, nil }}
	destination := netip.MustParseAddr("10.12.166.207")
	for _, expected := range []int{1, 2, 1} {
		index = expected
		got, err := f.ByAddr(destination)
		if err != nil || got.Index != expected {
			t.Fatalf("route change: got %v, %v; want index %d", got, err, expected)
		}
	}
}

func TestNativeRouteLookup(t *testing.T) {
	index, err := routeInterfaceIndex(netip.MustParseAddr("127.0.0.1"))
	if err != nil {
		t.Fatal(err)
	}
	iface, err := net.InterfaceByIndex(index)
	if err != nil || iface.Flags&net.FlagLoopback == 0 {
		t.Fatalf("loopback route: index %d, interface %v, error %v", index, iface, err)
	}
	if _, err := routeInterfaceIndex(netip.Addr{}); err == nil {
		t.Fatal("invalid address accepted")
	}
}

func TestConcurrentNativeRouteLookup(t *testing.T) {
	for _, address := range []string{"127.0.0.1", "1.1.1.1"} {
		destination := netip.MustParseAddr(address)
		want, err := routeInterfaceIndex(destination)
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 12; i++ {
			t.Run(address, func(t *testing.T) {
				t.Parallel()
				index, err := routeInterfaceIndex(destination)
				if err != nil || index != want {
					t.Errorf("%s: got index %d, %v; want %d", destination, index, err, want)
				}
			})
		}
	}
}
