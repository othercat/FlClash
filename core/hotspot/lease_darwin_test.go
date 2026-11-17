package hotspot

import (
	"errors"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func currentPID() int { return os.Getpid() }

func TestPFLeaseOwnsOnlyItsReferenceAndRecoversInvalidation(t *testing.T) {
	now := time.Unix(1000, 0)
	refs := []pfReference{{value: 10, pid: 31, name: "aTrustXtunnel"}, {value: 20, pid: 32, name: "FlClashCore"}, {value: 30, pid: 33, name: "FlClashCore"}}
	starts := 0
	var stopped []uint64
	l := &pfLease{
		list: func() ([]pfReference, error) { return refs, nil },
		start: func() (uint64, error) {
			starts++
			token := uint64(100 + starts)
			refs = append(refs, pfReference{value: token, pid: os.Getpid(), name: "FlClashCore"})
			return token, nil
		},
		stop: func(token uint64) error {
			if starts == 0 {
				t.Fatal("orphan cleanup disabled PF before acquiring own reference")
			}
			stopped = append(stopped, token)
			return nil
		},
		dead: func(pid int) bool { return pid == 32 || pid == 31 }, now: func() time.Time { return now },
	}
	if err := l.ensure(); err != nil || starts != 1 || len(stopped) != 1 || stopped[0] != 20 {
		t.Fatalf("foreign/live references touched: starts=%d stopped=%v err=%v", starts, stopped, err)
	}
	if err := l.ensure(); err != nil || starts != 1 {
		t.Fatal("healthy lease duplicated", err)
	}
	refs = nil // Actual DIOCSTOP invalidates all references.
	if err := l.ensure(); err == nil || starts != 1 {
		t.Fatal("external reset not bounded")
	}
	now = now.Add(10 * time.Second)
	if err := l.ensure(); err != nil || starts != 2 {
		t.Fatal("own reference not reacquired", err)
	}
	if err := l.close(); err != nil || l.token != 0 || stopped[len(stopped)-1] != 102 {
		t.Fatal("own reference not released", err)
	}
	if err := l.ensure(); err != nil || starts != 3 {
		t.Fatal("explicit disable/re-enable kept recovery cooldown", err)
	}
	if err := l.close(); err != nil {
		t.Fatal(err)
	}
}

func TestPFLeaseErrorsNeverFallBackToGlobalDisable(t *testing.T) {
	now := time.Unix(1000, 0)
	starts := 0
	l := &pfLease{list: func() ([]pfReference, error) { return nil, nil }, start: func() (uint64, error) { starts++; return 0, errors.New("denied") }, now: func() time.Time { return now }}
	if l.ensure() == nil || l.ensure() == nil || starts != 1 {
		t.Fatal("failed acquisition was unbounded")
	}
	l.token = 7
	l.list = func() ([]pfReference, error) { return []pfReference{{value: 7, pid: os.Getpid()}}, nil }
	l.stop = func(uint64) error { return errors.New("busy") }
	if l.close() == nil || l.token != 7 {
		t.Fatal("cleanup failure lost owned reference")
	}
	l.stop = func(uint64) error { return unix.EINVAL }
	if l.close() != nil || l.token != 0 {
		t.Fatal("invalidated own reference could not close")
	}
}

func TestPFLeaseDoesNotReleaseReusedForeignToken(t *testing.T) {
	l := &pfLease{token: 7, list: func() ([]pfReference, error) {
		return []pfReference{{value: 7, pid: 99999, name: "aTrustXtunnel"}}, nil
	}, stop: func(uint64) error { t.Fatal("released a token now owned by another process"); return nil }}
	if err := l.close(); err != nil || l.token != 0 {
		t.Fatal("stale reference was not discarded", err)
	}
}
