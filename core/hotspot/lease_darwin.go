package hotspot

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"runtime"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin's DIOCSTARTREF / DIOCSTOPREF, not a global PF enable/disable.
// XNU pfvar.h has a packed 84-byte pfioc_token and 16-byte pfioc_tokens.
// Tokens remain private to this native core; no shell output or token file.
type pfReference struct {
	value uint64
	pid   int
	name  string
}

type pfLease struct {
	token     uint64
	list      func() ([]pfReference, error)
	start     func() (uint64, error)
	stop      func(uint64) error
	dead      func(int) bool
	now       func() time.Time
	nextRetry time.Time
}

func newPFLease() *pfLease {
	return &pfLease{list: readPFReferences, start: startPFReference, stop: stopPFReference, dead: func(pid int) bool { return pid > 1 && unix.Kill(pid, 0) == unix.ESRCH }, now: time.Now}
}

func (l *pfLease) ensure() error {
	refs, err := l.list()
	if err != nil {
		return fmt.Errorf("read PF reference ownership: %w", err)
	}
	for _, r := range refs {
		if l.token != 0 && r.value == l.token && r.pid == os.Getpid() {
			return nil
		}
	}
	// A global external -d invalidates all tokens, even if PF was re-enabled.
	// Reacquire only our reference, with bounded retries; never reuse a stale one.
	l.token = 0
	if l.now().Before(l.nextRetry) {
		return errors.New("PF reference recovery is cooling down")
	}
	l.nextRetry = l.now().Add(10 * time.Second)
	token, err := l.start()
	if err != nil {
		return fmt.Errorf("acquire own PF reference: %w", err)
	}
	if token == 0 {
		return errors.New("PF returned an empty reference")
	}
	l.token = token
	// Recover leaked references from crashed cores only after taking ours, so
	// cleanup cannot turn PF off underneath an active gateway. Never touch a
	// live core or another program's reference, including aTrust/system sharing.
	for _, r := range refs {
		if r.name == "FlClashCore" && l.dead(r.pid) {
			if err := l.releaseMatching(r); err != nil && !invalidPFReference(err) {
				return errors.New("could not release an orphan FlClash PF reference")
			}
		}
	}
	return nil
}

func (l *pfLease) releaseMatching(expected pfReference) error {
	// A global reset can invalidate and reuse a token value for another
	// process. Recheck the kernel's owner immediately before releasing it.
	refs, err := l.list()
	if err != nil {
		return errors.New("could not verify PF reference ownership")
	}
	for _, r := range refs {
		if r.value == expected.value && r.pid == expected.pid && (expected.name == "" || r.name == expected.name) {
			return l.stop(r.value)
		}
	}
	return nil
}

func invalidPFReference(err error) bool {
	return errors.Is(err, unix.ENOENT) || errors.Is(err, unix.EINVAL) || errors.Is(err, unix.ESRCH)
}

func (l *pfLease) close() error {
	if l == nil || l.token == 0 {
		return nil
	}
	if err := l.releaseMatching(pfReference{value: l.token, pid: os.Getpid()}); err != nil && !invalidPFReference(err) {
		return errors.New("could not release own PF reference")
	}
	l.token = 0
	l.nextRetry = time.Time{}
	return nil
}

func startPFReference() (uint64, error) {
	f, err := os.OpenFile("/dev/pf", os.O_RDWR, 0)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	var token uint64
	// DIOCSTARTREF is _IOR, unlike the existing rule/list _IOWR requests.
	request := uintptr(0x40000000 | (8 << 16) | ('D' << 8) | 8)
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, f.Fd(), request, uintptr(unsafe.Pointer(&token)))
	runtime.KeepAlive(&token)
	if errno != 0 {
		return 0, fmt.Errorf("PF acquire reference: %w", errno)
	}
	return token, nil
}

func stopPFReference(token uint64) error {
	f, err := os.OpenFile("/dev/pf", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	request := [2]uint64{token, 0}
	return pfIO(f.Fd(), 9, unsafe.Pointer(&request), unsafe.Sizeof(request))
}

func readPFReferences() ([]pfReference, error) {
	f, err := os.OpenFile("/dev/pf", os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var request struct {
		Size    int32
		Padding uint32
		Buffer  unsafe.Pointer
	}
	if err := pfIO(f.Fd(), 5, unsafe.Pointer(&request), unsafe.Sizeof(request)); err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil, nil
		}
		return nil, err
	}
	const entrySize = 84
	if request.Size < 0 || request.Size > 4096*entrySize || request.Size%entrySize != 0 {
		return nil, errors.New("unsupported PF reference list ABI")
	}
	if request.Size == 0 {
		return nil, nil
	}
	// Leave room for concurrent enable references between the two reads.
	buffer := make([]byte, int(request.Size)+8*entrySize)
	request.Size = int32(len(buffer))
	request.Buffer = unsafe.Pointer(&buffer[0])
	if err := pfIO(f.Fd(), 5, unsafe.Pointer(&request), unsafe.Sizeof(request)); err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil, nil
		}
		return nil, err
	}
	runtime.KeepAlive(buffer)
	if request.Size < 0 || int(request.Size) > len(buffer) || request.Size%entrySize != 0 {
		return nil, errors.New("invalid PF reference list")
	}
	if int(request.Size) == len(buffer) {
		return nil, errors.New("PF reference list changed during read")
	}
	var refs []pfReference
	for offset := 0; offset < int(request.Size); offset += entrySize {
		b := buffer[offset : offset+entrySize]
		refs = append(refs, pfReference{value: binary.LittleEndian.Uint64(b[:8]), pid: int(int32(binary.LittleEndian.Uint32(b[16:20]))), name: string(bytes.TrimRight(b[20:84], "\x00"))})
	}
	return refs, nil
}
