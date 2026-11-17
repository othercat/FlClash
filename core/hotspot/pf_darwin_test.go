package hotspot

import (
	"os"
	"testing"
	"unsafe"
)

// This optional root-only test reads the current ABI and parses a candidate
// ruleset. It never loads rules, requests a PF token, or modifies state.
func TestDarwinPFReadOnlyPreflight(t *testing.T) {
	if unsafe.Sizeof(pfRule{}) != 3104 {
		t.Fatal("PF request layout changed")
	}
	if os.Geteuid() != 0 {
		t.Skip("read-only PF ABI check requires root")
	}
	f, err := os.OpenFile("/dev/pf", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, action := range []byte{0, 8} {
		if _, err := rootCalls(f.Fd(), action); err != nil {
			t.Fatal(err)
		}
	}
	env := Environment{Running: true, DNSReady: true, TunDevice: "utun4", TunAddress: testLink().TunAddress}
	p := newPlatform().(*darwinPlatform)
	l, err := p.detect(env)
	if err != nil {
		t.Skipf("no active Internet Sharing for syntax check: %v", err)
	}
	raw, err := rules(l, 23456)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = command(raw, "/sbin/pfctl", "-n", "-a", p.anchor, "-f", "-"); err != nil {
		t.Fatal(err)
	}
}
