package hotspot

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestDarwinRepairsExternalResetWithoutFlushingConnections(t *testing.T) {
	l := testLink()
	p := newPlatform().(*darwinPlatform)
	p.installed, p.link, p.policy = true, l, "previous-policy"
	forward := uint32(0)
	writes, loads, retired, hookCount := 0, 0, 0, 0
	filter, redirect := "", ""
	hooks := false
	p.forwarding = forwardingRecovery{
		read:  func() (uint32, error) { return forward, nil },
		write: func() error { writes++; forward = 1; return nil },
		now:   time.Now,
	}
	p.pf = pfOperations{
		command: func(input string, args ...string) (string, error) {
			joined := strings.Join(args, " ")
			if strings.HasSuffix(joined, " -sr") {
				return filter, nil
			}
			if strings.HasSuffix(joined, " -sn") {
				return redirect, nil
			}
			if !strings.Contains(joined, " -a "+p.anchor+" -f -") || !strings.Contains(input, "port 23456") {
				t.Fatalf("unexpected privileged command: %s", joined)
			}
			if strings.Contains(joined, " -n ") {
				return "", nil
			}
			loads++
			filter, redirect = "own-filter", "own-redirect"
			return "", nil
		},
		hooks: func(name string) (bool, error) {
			if name != p.anchor {
				t.Fatal("checked another owner's hooks")
			}
			return hooks, nil
		},
		ensure: func(name string, action byte) error {
			if name != p.anchor || (action != 0 && action != 8) {
				t.Fatal("changed another owner's hooks")
			}
			hookCount++
			hooks = hookCount == 2
			return nil
		},
		retire: func(link) error { retired++; return nil },
	}
	if err := p.maintain(l, 23456); err != nil {
		t.Fatal(err)
	}
	if forward != 1 || writes != 1 || loads != 1 || hookCount != 2 || retired != 0 {
		t.Fatalf("unsafe/incomplete recovery: forwarding=%d writes=%d loads=%d hooks=%d state-flushes=%d", forward, writes, loads, hookCount, retired)
	}
	if err := p.maintain(l, 23456); err != nil || loads != 1 || writes != 1 || retired != 0 {
		t.Fatalf("healthy policy unnecessarily replaced: %v", err)
	}
	l.HostAddresses = "127.0.0.1/8 10.1.2.3/32"
	p.nextPolicyRetry = time.Time{}
	if err := p.maintain(l, 23456); err != nil || retired != 0 || loads != 2 {
		t.Fatalf("local address refresh retired live connections: %v", err)
	}
}

func TestDarwinDoesNotLearnEmptyPolicyAfterConcurrentFlush(t *testing.T) {
	p := newPlatform().(*darwinPlatform)
	l := testLink()
	p.installed, p.link, p.policy = true, l, "old-filter\n--RDR--\nold-redirect"
	p.forwarding = forwardingRecovery{read: func() (uint32, error) { return 1, nil }, now: time.Now}
	filter, redirect := "", ""
	flushAfterLoad := true
	p.pf = pfOperations{
		command: func(input string, args ...string) (string, error) {
			s := strings.Join(args, " ")
			if strings.HasSuffix(s, " -sr") {
				return filter, nil
			}
			if strings.HasSuffix(s, " -sn") {
				return redirect, nil
			}
			if !strings.Contains(s, " -a "+p.anchor+" -f -") {
				t.Fatalf("out-of-scope command: %s", s)
			}
			if !strings.Contains(s, " -n ") && !flushAfterLoad {
				filter, redirect = "new-filter", "new-redirect"
			}
			return "", nil
		},
		hooks:  func(string) (bool, error) { return true, nil },
		ensure: func(string, byte) error { return nil },
		retire: func(link) error { t.Fatal("retired states during recovery"); return nil },
	}
	if err := p.maintain(l, 23456); err == nil || p.policy != "old-filter\n--RDR--\nold-redirect" {
		t.Fatal("an empty concurrently flushed child became the healthy baseline")
	}
	p.nextPolicyRetry = time.Time{}
	flushAfterLoad = false
	if err := p.maintain(l, 23456); err != nil || !completePolicy(p.policy) {
		t.Fatal("failed to recover the next intact policy")
	}
}

func TestDarwinPolicyRecoveryIsBoundedAndReportsFailures(t *testing.T) {
	p := newPlatform().(*darwinPlatform)
	l := testLink()
	p.installed, p.link, p.policy = true, l, "old"
	p.forwarding = forwardingRecovery{read: func() (uint32, error) { return 1, nil }, now: time.Now}
	writes := 0
	p.pf = pfOperations{
		command: func(input string, args ...string) (string, error) {
			if strings.HasSuffix(strings.Join(args, " "), " -sr") || strings.HasSuffix(strings.Join(args, " "), " -sn") {
				return "", nil
			}
			writes++
			return "", errors.New("PF changed concurrently")
		},
		hooks: func(string) (bool, error) { return false, nil },
	}
	if err := p.maintain(l, 23456); err == nil || writes != 1 {
		t.Fatal("failed validation was not reported")
	}
	l.HostAddresses = "changed-during-cooldown"
	if err := p.maintain(l, 23456); err == nil || writes != 1 {
		t.Fatal("failed repair immediately repeated privileged commands")
	}
}
