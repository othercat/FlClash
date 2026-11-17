package hotspot

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
	"unsafe"
)

func TestPFPolicyVersionUsesOnlyReadRequestsAndDetectsRaces(t *testing.T) {
	calls := 0
	race := false
	control := func(_ uintptr, number uintptr, data unsafe.Pointer, size uintptr) error {
		if number != 6 || size != 3104 {
			t.Fatal("version check attempted a write or unknown PF ABI")
		}
		r := (*pfRule)(data)
		if string(bytes.TrimRight(r.Anchor[:], "\x00")) != "flclash-hotspot-123" {
			t.Fatal("version check read another anchor")
		}
		action := r.Rule[ruleActionOffset]
		if action != 0 && action != 8 {
			t.Fatal("version check read an unrelated ruleset")
		}
		calls++
		r.Ticket, r.Nr = uint32(10+action), 2
		if race && calls >= 3 {
			r.Ticket++
		}
		return nil
	}
	v, err := pfPolicyVersionWithControl(0, "flclash-hotspot-123", control)
	if err != nil || !v.complete() || v.FilterTicket != 10 || v.RedirectTicket != 18 || calls != 4 {
		t.Fatalf("invalid snapshot=%+v err=%v reads=%d", v, err, calls)
	}
	calls, race = 0, true
	if _, err := pfPolicyVersionWithControl(0, "flclash-hotspot-123", control); err == nil {
		t.Fatal("mixed concurrent PF generations were accepted")
	}
}

func TestNativePolicyMaintenanceRetainsResetRecoveryWithoutCommands(t *testing.T) {
	p := newPlatform().(*darwinPlatform)
	l := testLink()
	v := pfPolicyVersion{FilterTicket: 11, FilterCount: 2, RedirectTicket: 12, RedirectCount: 1}
	p.installed, p.link, p.policy = true, l, "own-filter\n--RDR--\nown-rdr"
	p.policyVersion, p.versionValid = v, true
	forward, hooks := uint32(1), true
	writes, commands, loads := 0, 0, 0
	failNative := false
	p.forwarding = forwardingRecovery{read: func() (uint32, error) { return forward, nil }, write: func() error { writes++; forward = 1; return nil }, now: time.Now}
	p.pf = pfOperations{
		version: func(name string) (pfPolicyVersion, error) {
			if name != p.anchor {
				t.Fatal("read foreign child")
			}
			if failNative {
				return pfPolicyVersion{}, errors.New("unsupported native read")
			}
			return v, nil
		},
		hooks: func(string) (bool, error) { return hooks, nil },
		ensure: func(name string, _ byte) error {
			if name != p.anchor {
				t.Fatal("changed foreign root call")
			}
			hooks = true
			return nil
		},
		retire: func(link) error { t.Fatal("same-path repair retired active connections"); return nil },
		command: func(input string, args ...string) (string, error) {
			commands++
			s := strings.Join(args, " ")
			if strings.HasSuffix(s, " -sr") {
				return "own-filter", nil
			}
			if strings.HasSuffix(s, " -sn") {
				return "own-rdr", nil
			}
			if !strings.Contains(s, " -a "+p.anchor+" -f -") || input == "" {
				t.Fatal("repair attempted out-of-scope command", s)
			}
			if !strings.Contains(s, " -n ") {
				loads++
				v.FilterTicket++
				v.RedirectTicket++
				v.FilterCount, v.RedirectCount = 2, 1
			}
			return "", nil
		},
	}
	for i := 0; i < 12; i++ {
		if err := p.maintain(l, 23456); err != nil {
			t.Fatal(err)
		}
	}
	if commands != 0 || writes != 0 {
		t.Fatal("healthy PF maintenance launched commands or rewrote forwarding")
	}
	// Model aTrust's reset. Restore on this very check, not a slow cache expiry.
	forward, hooks, v.FilterCount = 0, false, 0
	if err := p.maintain(l, 23456); err != nil || loads != 1 || writes != 1 || !p.versionValid {
		t.Fatalf("external reset not restored: %v loads=%d writes=%d", err, loads, writes)
	}
	before := commands
	if err := p.maintain(l, 23456); err != nil || commands != before {
		t.Fatal("recovered policy still spawned healthy-path commands", err)
	}
	// Same rule count, different transaction must also be detected.
	v.RedirectTicket++
	p.nextPolicyRetry = time.Time{}
	if err := p.maintain(l, 23456); err != nil || loads != 2 {
		t.Fatal("changed child generation was missed", err)
	}
	failNative = true
	before = commands
	if err := p.maintain(l, 23456); err != nil || commands != before+2 || loads != 2 {
		t.Fatal("unsupported native read lost safe text validation", err)
	}
}

// Explicit opt-in by running only this test as administrator: read existing
// anchors and compare native generation/counts with pfctl output. No rules,
// references, counters, forwarding, DNS or application lifecycle are modified.
func TestPFPolicyVersionLiveReadOnly(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("read-only live PF check requires root")
	}
	f, err := os.OpenFile("/dev/pf", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	calls, err := rootCalls(f.Fd(), 0)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, call := range calls {
		name := callName(call)
		if !strings.HasPrefix(name, "flclash-hotspot-") && !strings.HasPrefix(name, "flclash-router-") {
			continue
		}
		before, err := readPFPolicyVersion(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, action := range []string{"-sr", "-sn"} {
			out, err := command("", "/sbin/pfctl", "-a", name, action)
			if err != nil || strings.TrimSpace(out) == "" {
				t.Fatalf("active child %s has no policy: %v", name, err)
			}
		}
		after, err := readPFPolicyVersion(name)
		if err != nil || before != after || !after.complete() {
			t.Fatalf("native child generation is inconsistent: %v before=%+v after=%+v", err, before, after)
		}
		checked++
	}
	if checked == 0 {
		t.Skip("no active FlClash gateway anchors; no changes attempted")
	}
	t.Logf("verified %d existing gateway children with read-only requests", checked)
}
