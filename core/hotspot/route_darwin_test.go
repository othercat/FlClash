package hotspot

import (
	"strings"
	"syscall"
	"testing"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

func defaultRouteFixture(index, flags int, mask [4]byte) *route.RouteMessage {
	return &route.RouteMessage{Index: index, Flags: flags, Addrs: []route.Addr{
		unix.RTAX_DST:     &route.Inet4Addr{},
		unix.RTAX_NETMASK: &route.Inet4Addr{IP: mask},
	}}
}

func TestNativeDefaultRouteSelection(t *testing.T) {
	messages := []route.Message{
		defaultRouteFixture(2, unix.RTF_UP|unix.RTF_IFSCOPE, [4]byte{}),
		defaultRouteFixture(3, unix.RTF_UP|unix.RTF_REJECT, [4]byte{}),
		defaultRouteFixture(4, unix.RTF_UP, [4]byte{255, 0, 0, 0}),
		defaultRouteFixture(5, unix.RTF_UP|unix.RTF_GATEWAY, [4]byte{}),
	}
	messages[3].(*route.RouteMessage).Err = syscall.Errno(53584) // observed dump metadata, not a socket error
	if got, err := defaultRouteIndex(messages); err != nil || got != 5 {
		t.Fatalf("default interface=%d err=%v", got, err)
	}
	messages = append(messages, defaultRouteFixture(6, unix.RTF_UP|unix.RTF_GATEWAY, [4]byte{}))
	if _, err := defaultRouteIndex(messages); err == nil {
		t.Fatal("ambiguous routes selected an arbitrary LAN")
	}
	if _, err := defaultRouteIndex(nil); err == nil {
		t.Fatal("missing default route was accepted")
	}
}

func TestNativeDefaultRouteMatchesReadOnlySystemQuery(t *testing.T) {
	name, err := defaultRouteInterface()
	if err != nil {
		t.Skipf("native RIB unavailable; production keeps command fallback: %v", err)
	}
	out, err := command("", "/sbin/route", "-n", "get", "default")
	if err != nil {
		t.Skipf("read-only route query unavailable: %v", err)
	}
	for _, row := range strings.Split(out, "\n") {
		fields := strings.Fields(row)
		if len(fields) == 2 && fields[0] == "interface:" {
			if name != fields[1] {
				t.Fatalf("native=%s command=%s", name, fields[1])
			}
			return
		}
	}
	t.Fatal("system route query has no interface")
}
