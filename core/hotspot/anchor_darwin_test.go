package hotspot

import (
	"reflect"
	"strings"
	"testing"
	"unsafe"
)

// Model only the documented individual-rule PF ioctls. No test opens /dev/pf,
// changes the host policy, or touches a real VPN. This exercises the actual
// request emitted by ensureAnchor, rather than an independent ordering helper.
type anchorKernel struct {
	t       *testing.T
	rules   map[byte][]pfRule
	changes int
}

func (k *anchorKernel) control(_ uintptr, number uintptr, data unsafe.Pointer, size uintptr) error {
	if number == 51 {
		if size != 1136 {
			k.t.Fatal("unexpected address-pool ABI")
		}
		(*[284]uint32)(data)[1] = 23
		return nil
	}
	if size != unsafe.Sizeof(pfRule{}) {
		k.t.Fatal("unexpected rule ABI")
	}
	r := (*pfRule)(data)
	action := r.Rule[ruleActionOffset]
	list := k.rules[action]
	switch number {
	case 6: // DIOCGETRULES
		r.Ticket, r.Nr = 17, uint32(len(list))
	case 7: // DIOCGETRULE
		if r.Ticket != 17 || int(r.Nr) >= len(list) {
			k.t.Fatal("invalid rule read")
		}
		nr := r.Nr
		*r = list[nr]
		r.Nr, r.Ticket = nr, 17
	case 26: // DIOCCHANGERULE
		switch r.Action {
		case 6: // PF_CHANGE_GET_TICKET
			r.Ticket = 17
		case 1, 2: // PF_CHANGE_ADD_HEAD / PF_CHANGE_ADD_TAIL
			if r.Ticket != 17 || r.PoolTicket != 23 {
				k.t.Fatal("invalid individual-rule transaction")
			}
			if r.Action == 1 {
				k.rules[action] = append([]pfRule{*r}, list...)
			} else {
				k.rules[action] = append(list, *r)
			}
			k.changes++
		default:
			k.t.Fatalf("unexpected root policy operation: %d", r.Action)
		}
	default:
		k.t.Fatalf("unexpected PF ioctl: %d", number)
	}
	return nil
}

func anchorFixture(name string, action byte) pfRule {
	var r pfRule
	copy(r.Call[:], name)
	r.Rule[ruleActionOffset] = action
	return r
}

func anchorNames(rules []pfRule) []string {
	names := make([]string, len(rules))
	for i, r := range rules {
		names[i] = callName(r)
	}
	return names
}

func TestDarwinAnchorPreservesVPNPrefixAndHotspotDNSPrecedence(t *testing.T) {
	// Captured host order. aTrust compares the checked prefix by index after
	// skipping Internet Sharing rows; trailing extra FILTER calls are allowed.
	expected := []string{"com.sangfor.atrust", "com.sangfor.atrust1", "com.sangfor.vpn", "com.sangfor.app01", "com.sangfor.app02", "com.sangfor.byod"}
	compatiblePrefix := func(names []string) bool {
		var filtered []string
		for _, name := range names {
			if !strings.Contains(name, "com.apple.internet-sharing") {
				filtered = append(filtered, name)
			}
		}
		return len(filtered) >= len(expected) && reflect.DeepEqual(filtered[:len(expected)], expected)
	}
	base := append(append([]string{}, expected...), "com.apple.internet-sharing")
	const own = "flclash-hotspot-12345"
	if compatiblePrefix(append([]string{own}, base...)) {
		t.Fatal("the old prepend behavior must reproduce the VPN prefix conflict")
	}
	k := &anchorKernel{t: t, rules: make(map[byte][]pfRule)}
	for _, name := range base {
		k.rules[0] = append(k.rules[0], anchorFixture(name, 0))
	}
	k.rules[8] = []pfRule{anchorFixture("com.apple.internet-sharing", 8)}
	if err := ensureAnchorWithControl(0, own, 0, k.control); err != nil {
		t.Fatal(err)
	}
	filter := anchorNames(k.rules[0])
	if !compatiblePrefix(filter) || !reflect.DeepEqual(filter[:len(base)], base) || filter[len(base)] != own {
		t.Fatalf("foreign FILTER prefix changed: %v", filter)
	}
	added := k.rules[0][len(base)]
	if added.Rule[ruleQuickOffset] != 1 || added.Rule[ruleActionOffset+1] != 1 {
		t.Fatal("hotspot FILTER must remain quick and inbound")
	}
	if err := ensureAnchorWithControl(0, own, 8, k.control); err != nil {
		t.Fatal(err)
	}
	if got := anchorNames(k.rules[8]); !reflect.DeepEqual(got, []string{own, "com.apple.internet-sharing"}) {
		t.Fatalf("hotspot DNS lost RDR precedence: %v", got)
	}
	if !reflect.DeepEqual(anchorNames(k.rules[0]), filter) {
		t.Fatal("RDR insertion changed the VPN FILTER rules")
	}
	for _, action := range []byte{0, 8} {
		if err := ensureAnchorWithControl(0, own, action, k.control); err != nil {
			t.Fatal(err)
		}
	}
	if k.changes != 2 {
		t.Fatal("healthy hooks were rewritten")
	}
}
