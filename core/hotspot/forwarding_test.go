package hotspot

import (
	"errors"
	"testing"
	"time"
)

func TestForwardingRecoveryWritesOnlyAfterAReset(t *testing.T) {
	value := uint32(1)
	writes := 0
	now := time.Unix(1000, 0)
	f := forwardingRecovery{
		read:  func() (uint32, error) { return value, nil },
		write: func() error { writes++; value = 1; return nil },
		now:   func() time.Time { return now },
	}
	if restored, err := f.ensure(); err != nil || restored || writes != 0 {
		t.Fatal("healthy forwarding was rewritten")
	}
	value = 0
	if restored, err := f.ensure(); err != nil || !restored || writes != 1 || value != 1 {
		t.Fatalf("reset not repaired: restored=%v, err=%v, writes=%d", restored, err, writes)
	}
	value = 0
	if _, err := f.ensure(); err == nil || writes != 1 {
		t.Fatal("repeated external reset was not rate limited")
	}
	now = now.Add(10 * time.Second)
	if restored, err := f.ensure(); err != nil || !restored || writes != 2 {
		t.Fatal("recovery did not retry after cooldown")
	}
}

func TestForwardingRecoveryRequiresSuccessfulReadback(t *testing.T) {
	for _, scenario := range []string{"read", "write", "not-restored"} {
		t.Run(scenario, func(t *testing.T) {
			writes := 0
			f := forwardingRecovery{
				read: func() (uint32, error) {
					if scenario == "read" {
						return 0, errors.New("read denied")
					}
					return 0, nil
				},
				write: func() error {
					writes++
					if scenario == "write" {
						return errors.New("write denied")
					}
					return nil
				},
				now: func() time.Time { return time.Unix(1000, 0) },
			}
			if restored, err := f.ensure(); err == nil || restored {
				t.Fatalf("%s failure reported recovery", scenario)
			}
			if scenario == "read" && writes != 0 {
				t.Fatal("write attempted after a read failure")
			}
		})
	}
}
