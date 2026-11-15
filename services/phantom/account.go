package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	errAccountMissing  = errors.New("account-file-missing")
	errAccountFormat   = errors.New("account-file-format")
	errAccountRead     = errors.New("account-file-unreadable")
	errAccountRejected = errors.New("account-rejected")
)

type account struct{ user, pass string }

func readAccount() (account, error) {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return account{}, errAccountRead
	}
	path := filepath.Join(home, "fishport-pass.txt")
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return account{}, errAccountMissing
	}
	if err != nil || !info.Mode().IsRegular() {
		return account{}, errAccountRead
	}
	f, err := os.Open(path)
	if err != nil {
		return account{}, errAccountRead
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil {
		return account{}, errAccountRead
	}
	text := strings.TrimPrefix(strings.ReplaceAll(string(b), "\r\n", "\n"), "\uFEFF")
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	if len(b) > 8192 || !utf8.Valid(b) || strings.ContainsAny(text, "\r\x00") || len(lines) != 2 || strings.TrimSpace(lines[0]) == "" || lines[1] == "" {
		return account{}, errAccountFormat
	}
	return account{strings.TrimSpace(lines[0]), lines[1]}, nil
}

// Only a login the vendor accepted can reuse the encrypted device session.
// Key the comparison with the device's private panel gate to avoid a plaintext password hash.
func (a account) stamp(gate string) string {
	mac := hmac.New(sha256.New, []byte(gate))
	io.WriteString(mac, a.user+"\x00"+a.pass)
	return hex.EncodeToString(mac.Sum(nil))
}

func (p *panel) authenticate(ctx context.Context, dir string, configured bool, a account, gate string) error {
	path := filepath.Join(dir, "verified-login")
	stamp := a.stamp(gate)
	if configured {
		saved, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		var session loginResult
		err = p.call(ctx, "unlock", map[string]string{"admin_password": gate}, &session)
		if err != nil {
			return err
		}
		if session.Token == "" {
			return errors.New("local session unavailable")
		}
		p.token = session.Token
		if hmac.Equal(saved, []byte(stamp)) {
			if session.LocalOnly {
				// Preserve a verified account during a temporary upstream outage.
				return errors.New("online vendor account required")
			}
			return nil
		}
		// Invalidate the old binding before changing the official session, even
		// if the helper exits between setup and writing the new stamp.
		if err = os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		// The official setup endpoint accepts new credentials only after local logout.
		// This helper's private device identity is retained across account changes.
		if err = p.call(ctx, "logout", map[string]string{}, nil); err != nil {
			return err
		}
		p.token = ""
	}
	if err := p.login(ctx, "setup", map[string]string{"account": a.user, "password": a.pass, "admin_password": gate}); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(stamp), 0600)
}

func accountState(err error) string {
	switch {
	case errors.Is(err, errAccountMissing):
		return errAccountMissing.Error()
	case errors.Is(err, errAccountFormat):
		return errAccountFormat.Error()
	case errors.Is(err, errAccountRead):
		return errAccountRead.Error()
	case errors.Is(err, errAccountRejected):
		return errAccountRejected.Error()
	case errors.Is(err, errNative):
		return "native-runtime-unavailable"
	}
	var api *apiError
	if errors.As(err, &api) && api.code == 429 {
		return "rate-limited"
	}
	return "network-unavailable"
}

func (s *service) manage(ctx context.Context) {
	var dns, bootstrap string
	for ctx.Err() == nil {
		input, fileErr := readAccount()
		attempt, cancel := context.WithCancel(ctx)
		watched := make(chan struct{})
		go func() {
			defer close(watched)
			t := time.NewTicker(time.Second)
			defer t.Stop()
			for {
				select {
				case <-attempt.Done():
					return
				case <-t.C:
					if current, err := readAccount(); current != input || err != fileErr {
						cancel()
						return
					}
				}
			}
		}()
		err := fileErr
		if err == nil {
			s.status("starting", 0)
			// The vendor library caches its HTTP transport for the process lifetime.
			// Keep its loopback bootstrap address valid across credential edits.
			if bootstrap == "" {
				dns, bootstrap, err = startNetwork(ctx)
			}
			if err == nil {
				err = s.session(attempt, input, dns, bootstrap)
			}
		}
		if attempt.Err() == nil {
			state := accountState(err)
			s.status(state, 0)
			// Wait for the file to change after a local error or credential rejection.
			// Transient network errors retry even if the user has not edited the file.
			var retry <-chan time.Time
			if state == "rate-limited" {
				retry = time.After(5 * time.Minute)
			} else if fileErr == nil && !errors.Is(err, errAccountRejected) {
				retry = time.After(30 * time.Second)
			}
			select {
			case <-attempt.Done():
			case <-retry:
			}
		}
		cancel()
		<-watched
	}
}
