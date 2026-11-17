package hotspot

import (
	"net"
	"strings"
	"testing"
)

func TestRouterNativeSyntaxReadOnly(t *testing.T) {
	choices, err := routerInterfaces()
	if err != nil || len(choices) == 0 {
		t.Skip("no private LAN for syntax-only check")
	}
	env := routerTestEnvironment()
	interfaces, _ := net.Interfaces()
	env.TunDevice = ""
	for _, iface := range interfaces {
		if tunName.MatchString(iface.Name) && iface.Flags&net.FlagUp != 0 {
			env.TunDevice = iface.Name
		}
	}
	if env.TunDevice == "" {
		t.Skip("no interface for syntax-only route-to parsing")
	}
	l, err := selectRouterLink(env, choices, "")
	if err != nil {
		t.Skipf("no unambiguous dual-stack LAN for syntax-only check: %v", err)
	}
	l.StateLabel = "flclash-router-424242"
	raw, err := rules(l, 1054)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := command(raw, "/sbin/pfctl", "-n", "-a", l.StateLabel, "-f", "-"); err != nil {
		t.Fatal(err)
	}
}

func TestRouterRecoveryNeverWritesGlobalForwardingOrFlushesLAN(t *testing.T) {
	p := newRouterPlatform().(*darwinPlatform)
	l, _ := selectRouterLink(routerTestEnvironment(), []LANInterface{routerTestChoice()}, "en0")
	l.StateLabel = p.anchor
	p.installed, p.link = true, l
	p.forwarding = forwardingRecovery{read: func() (uint32, error) { t.Fatal("router read global forwarding"); return 0, nil }, write: func() error { t.Fatal("router wrote global forwarding"); return nil }}
	p.lease = &pfLease{token: 1, list: func() ([]pfReference, error) { return []pfReference{{value: 1, pid: currentPID()}}, nil }}
	filter, redirect := "", ""
	loads := 0
	hooks := false
	hookCount := 0
	p.pf = pfOperations{
		command: func(input string, args ...string) (string, error) {
			joined := strings.Join(args, " ")
			if strings.HasSuffix(joined, " -sr") {
				return filter, nil
			}
			if strings.HasSuffix(joined, " -sn") {
				return redirect, nil
			}
			if !strings.Contains(joined, " -a "+p.anchor+" -f -") || !strings.Contains(input, "inet6") {
				t.Fatalf("out-of-scope PF operation: %s", joined)
			}
			if !strings.Contains(joined, " -n ") {
				loads++
				filter, redirect = "own-dual-filter", "own-dual-rdr"
			}
			return "", nil
		},
		hooks: func(string) (bool, error) { return hooks, nil },
		ensure: func(name string, action byte) error {
			if name != p.anchor {
				t.Fatal("foreign anchor changed")
			}
			hookCount++
			hooks = hookCount == 2
			return nil
		},
		retire: func(link) error { t.Fatal("same-path recovery retired connections"); return nil },
	}
	if err := p.maintain(l, 1054); err != nil {
		t.Fatal(err)
	}
	if err := p.maintain(l, 1054); err != nil || loads != 1 {
		t.Fatal("healthy router rewritten", err)
	}
	if err := discardClientStates(l); err != nil {
		t.Fatal(err)
	}
}
