package hotspot

import (
	"bytes"
	"fmt"
	"os"
	"runtime"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin's PF ABI (identical on amd64 and arm64), from Apple's pfvar.h:
// https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.1.10/bsd/net/pfvar.h
// Use only individual anchor-call changes. An unsupported ABI fails the read
// preflight before any change; we never fall back to reloading the root rules.
type pfRule struct {
	Action, Ticket, PoolTicket, Nr uint32
	Anchor, Call                   [1024]byte
	Rule                           [1040]byte
}

const ruleActionOffset = 1004
const ruleQuickOffset = 1008

type pfPolicyVersion struct {
	FilterTicket, FilterCount     uint32
	RedirectTicket, RedirectCount uint32
}

func (v pfPolicyVersion) complete() bool { return v.FilterCount > 0 && v.RedirectCount > 0 }

// DIOCGETRULES returns the active ruleset's ticket and count without modifying
// it. XNU increments tickets for transactions and individual rule changes:
// https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.1.10/bsd/net/pf_ioctl.c
// Packet counters do not affect tickets, unlike comparing raw pf_rule bytes.
func readPFPolicyVersion(name string) (pfPolicyVersion, error) {
	f, err := os.OpenFile("/dev/pf", os.O_RDONLY, 0)
	if err != nil {
		return pfPolicyVersion{}, err
	}
	defer f.Close()
	return pfPolicyVersionWithControl(f.Fd(), name, pfIO)
}

func pfPolicyVersionWithControl(fd uintptr, name string, control pfControl) (pfPolicyVersion, error) {
	if len(name) == 0 || len(name) >= 1024 || bytes.ContainsAny([]byte(name), "\x00/") {
		return pfPolicyVersion{}, fmt.Errorf("invalid PF child name")
	}
	read := func() (pfPolicyVersion, error) {
		var result pfPolicyVersion
		for _, action := range []byte{0, 8} {
			var request pfRule
			copy(request.Anchor[:], name)
			request.Rule[ruleActionOffset] = action
			if err := control(fd, 6, unsafe.Pointer(&request), unsafe.Sizeof(request)); err != nil {
				return result, err
			}
			if request.Nr > 4096 || request.Rule[ruleActionOffset] != action {
				return result, fmt.Errorf("unsupported PF child ABI")
			}
			if action == 0 {
				result.FilterTicket, result.FilterCount = request.Ticket, request.Nr
			} else {
				result.RedirectTicket, result.RedirectCount = request.Ticket, request.Nr
			}
		}
		return result, nil
	}
	first, err := read()
	if err != nil {
		return first, err
	}
	second, err := read()
	if err != nil {
		return second, err
	}
	if first != second {
		return second, fmt.Errorf("PF child changed during generation read")
	}
	return second, nil
}

type pfControl func(uintptr, uintptr, unsafe.Pointer, uintptr) error

func pfIO(fd uintptr, number uintptr, data unsafe.Pointer, size uintptr) error {
	request := uintptr(0xc0000000) | ((size & 0x1fff) << 16) | (uintptr('D') << 8) | number
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, fd, request, uintptr(data))
	runtime.KeepAlive(data)
	if errno != 0 {
		return fmt.Errorf("PF ioctl %d: %w", number, errno)
	}
	return nil
}

func rootCalls(fd uintptr, action byte) ([]pfRule, error) {
	return rootCallsWithControl(fd, action, pfIO)
}

func rootCallsWithControl(fd uintptr, action byte, control pfControl) ([]pfRule, error) {
	var request pfRule
	request.Rule[ruleActionOffset] = action
	if err := control(fd, 6, unsafe.Pointer(&request), unsafe.Sizeof(request)); err != nil {
		return nil, err
	}
	if request.Nr > 4096 {
		return nil, fmt.Errorf("unexpected root PF rule count: %d", request.Nr)
	}
	result := make([]pfRule, 0, request.Nr)
	for i := uint32(0); i < request.Nr; i++ {
		var r pfRule
		r.Ticket = request.Ticket
		r.Nr = i
		r.Rule[ruleActionOffset] = action
		if err := control(fd, 7, unsafe.Pointer(&r), unsafe.Sizeof(r)); err != nil {
			return nil, err
		}
		if r.Rule[ruleActionOffset] != action {
			return nil, fmt.Errorf("unsupported PF rule ABI")
		}
		result = append(result, r)
	}
	return result, nil
}

func callName(r pfRule) string { return string(bytes.TrimRight(r.Call[:], "\x00")) }

func ownAnchorsPresent(name string) (bool, error) {
	f, err := os.OpenFile("/dev/pf", os.O_RDONLY, 0)
	if err != nil {
		return false, err
	}
	defer f.Close()
	for _, action := range []byte{0, 8} {
		list, err := rootCalls(f.Fd(), action)
		if err != nil {
			return false, err
		}
		found := false
		for _, r := range list {
			if callName(r) == name {
				found = true
				break
			}
		}
		if !found {
			return false, nil
		}
	}
	return true, nil
}

func ensureAnchor(name string, action byte) error {
	f, err := os.OpenFile("/dev/pf", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	return ensureAnchorWithControl(f.Fd(), name, action, pfIO)
}

func ensureAnchorWithControl(fd uintptr, name string, action byte, control pfControl) error {
	list, err := rootCallsWithControl(fd, action, control)
	if err != nil {
		return err
	}
	for _, r := range list {
		if callName(r) == name {
			return nil
		}
	}
	// Begin an empty address pool for the anchor call, not a PF ruleset
	// transaction. No other rule or state is replaced.
	var pool [1136]byte
	if err = control(fd, 51, unsafe.Pointer(&pool), unsafe.Sizeof(pool)); err != nil {
		return err
	}
	var r pfRule
	r.Action = 6
	r.PoolTicket = *(*uint32)(unsafe.Pointer(&pool[4]))
	r.Rule[ruleActionOffset] = action
	copy(r.Call[:], name)
	if err = control(fd, 26, unsafe.Pointer(&r), unsafe.Sizeof(r)); err != nil {
		return err
	}
	r.Action = 1
	if action == 0 {
		// aTrust checks its existing FILTER prefix by row index. Prepending
		// ours makes it flush/reload all PF rules on its next health check.
		// Append only our call, preserving every existing rule and its order.
		// Internet Sharing's pass rules are not quick; the later scoped quick
		// route-to still sends hotspot clients through the TUN. Earlier VPN
		// quick rules retain their precedence. RDR stays first for hotspot DNS.
		r.Action = 2 // PF_CHANGE_ADD_TAIL
		r.Rule[ruleQuickOffset] = 1
		r.Rule[ruleActionOffset+1] = 1
	}
	return control(fd, 26, unsafe.Pointer(&r), unsafe.Sizeof(r))
}

func removeAnchor(name string, action byte) error {
	f, err := os.OpenFile("/dev/pf", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	list, err := rootCalls(f.Fd(), action)
	if err != nil {
		return err
	}
	for _, r := range list {
		if callName(r) != name {
			continue
		}
		var request pfRule
		request.Nr = r.Nr
		request.Rule[ruleActionOffset] = action
		request.Action = 6
		if err = pfIO(f.Fd(), 26, unsafe.Pointer(&request), unsafe.Sizeof(request)); err != nil {
			return err
		}
		// Apple can update and renumber its rules while sharing changes.
		// Recheck the identity under the new ticket before removing by number.
		verify := request
		verify.Action = 0
		if err = pfIO(f.Fd(), 7, unsafe.Pointer(&verify), unsafe.Sizeof(verify)); err != nil {
			return err
		}
		if callName(verify) != name {
			return fmt.Errorf("PF changed concurrently; retry cleanup")
		}
		request.Action = 5
		return pfIO(f.Fd(), 26, unsafe.Pointer(&request), unsafe.Sizeof(request))
	}
	return nil
}
