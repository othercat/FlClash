package hotspot

import (
	"fmt"
	"time"
)

// Called only after the manager verifies an opted-in session, a live TUN and
// the system's enabled Internet Sharing bridge. Never restore the old value
// on exit: Internet Sharing and other system services also own this flag.
type forwardingRecovery struct {
	read      func() (uint32, error)
	write     func() error
	now       func() time.Time
	nextRetry time.Time
}

func (f *forwardingRecovery) ensure() (bool, error) {
	value, err := f.read()
	if err != nil {
		return false, fmt.Errorf("read IPv4 forwarding: %w", err)
	}
	if value == 1 {
		return false, nil
	}
	if value != 0 {
		return false, fmt.Errorf("unexpected IPv4 forwarding value: %d", value)
	}
	now := f.now()
	if now.Before(f.nextRetry) {
		return false, fmt.Errorf("IPv4 forwarding recovery is cooling down after a recent attempt")
	}
	f.nextRetry = now.Add(10 * time.Second)
	if err := f.write(); err != nil {
		return false, fmt.Errorf("restore IPv4 forwarding: %w", err)
	}
	value, err = f.read()
	if err != nil || value != 1 {
		return false, fmt.Errorf("verify restored IPv4 forwarding: value=%d error=%v", value, err)
	}
	return true, nil
}
