package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestLoginFileUsesOnlyHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Chdir(t.TempDir())
	if err := os.WriteFile("fishport-pass.txt", []byte("adjacent\nignored"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readAccount(); !errors.Is(err, errAccountMissing) {
		t.Fatal("missing home file fell back to another location")
	}
	path := filepath.Join(home, "fishport-pass.txt")
	if err := os.WriteFile(path, []byte("\xef\xbb\xbftest@example.invalid\r\n  sample password  \r\n"), 0600); err != nil {
		t.Fatal(err)
	}
	value, err := readAccount()
	if err != nil || value.user != "test@example.invalid" || value.pass != "  sample password  " {
		t.Fatal("portable two-line login was not read intact")
	}
	if err = os.WriteFile(path, []byte("test@example.invalid\none\ntwo\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = readAccount(); !errors.Is(err, errAccountFormat) {
		t.Fatal("ambiguous login file was accepted")
	}
}

func TestAuthenticateRejectsChangedFileEvenWithCachedSession(t *testing.T) {
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := strings.TrimPrefix(r.URL.Path, "/consumer/")
		calls = append(calls, method)
		switch method {
		case "setup":
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Error(err)
			}
			if payload["account"] != "fixture" || payload["password"] != "valid" {
				w.WriteHeader(400)
				io.WriteString(w, `{"ok":false,"code":"relay_query_failed","error":"邮箱或密码错误"}`)
				return
			}
			fallthrough
		case "unlock":
			io.WriteString(w, `{"token":"fixture-session","local_only":false}`)
		case "logout":
			if r.Header.Get("Authorization") != "Bearer fixture-session" {
				t.Error("local logout was not authenticated")
			}
		default:
			t.Error("unexpected request")
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	auth := func(configured bool, a account, steps []string, want error) {
		t.Helper()
		calls = nil
		p := panel{url: server.URL, client: server.Client()}
		err := p.authenticate(context.Background(), dir, configured, a, "local-fixture")
		if !errors.Is(err, want) || !slices.Equal(calls, steps) {
			t.Fatalf("expected %v, got %v (%v)", steps, calls, accountState(err))
		}
	}
	valid := account{"fixture", "valid"}
	auth(false, valid, []string{"setup"}, nil)
	auth(true, valid, []string{"unlock"}, nil)
	auth(true, account{"fixture", "wrong"}, []string{"unlock", "logout", "setup"}, errAccountRejected)
	if _, err := os.Stat(filepath.Join(dir, "verified-login")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("rejected setup left an old credential binding")
	}
	auth(false, valid, []string{"setup"}, nil)
	// Earlier releases have no evidence that the home file matches their cached login.
	if err := os.Remove(filepath.Join(dir, "verified-login")); err != nil {
		t.Fatal(err)
	}
	auth(true, valid, []string{"unlock", "logout", "setup"}, nil)
}

func TestOfflineUnlockPreservesVerifiedAccount(t *testing.T) {
	dir := t.TempDir()
	a := account{"fixture", "valid"}
	gate := "local-fixture"
	path := filepath.Join(dir, "verified-login")
	if err := os.WriteFile(path, []byte(a.stamp(gate)), 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/consumer/unlock" {
			t.Error("offline unlock replaced the configured session")
		}
		io.WriteString(w, `{"token":"fixture-local","local_only":true}`)
	}))
	defer server.Close()
	p := panel{url: server.URL, client: server.Client()}
	err := p.authenticate(context.Background(), dir, true, a, gate)
	if err == nil || accountState(err) != "network-unavailable" {
		t.Fatal("an offline-only session was accepted or blamed on the password")
	}
	if saved, err := os.ReadFile(path); err != nil || string(saved) != a.stamp(gate) {
		t.Fatal("offline unlock lost the last verified login")
	}
}

func TestLoginErrorsAreScopedToCredentialRejection(t *testing.T) {
	for _, tc := range []struct {
		route, body string
		code        int
		state       string
	}{
		{"setup", `{"code":"relay_query_failed","error":"邮箱或密码错误"}`, 400, "account-rejected"},
		{"setup", `{"code":"relay_query_failed","error":"gateway timeout"}`, 400, "network-unavailable"},
		{"setup", `{}`, 429, "rate-limited"},
		{"unlock", `{}`, 401, "network-unavailable"},
		{"subscription", `{}`, 403, "network-unavailable"},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(tc.code)
			io.WriteString(w, tc.body)
		}))
		p := panel{url: server.URL, client: server.Client()}
		err := p.call(context.Background(), tc.route, map[string]string{}, nil)
		server.Close()
		if accountState(err) != tc.state {
			t.Fatalf("misclassified %s HTTP %d", tc.route, tc.code)
		}
	}
}

func TestSavedPanelPasswordSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	first, err := localPassword(dir, false)
	if err != nil {
		t.Fatal(err)
	}
	second, err := localPassword(dir, true)
	if err != nil || len(first) < 32 || first != second {
		t.Fatal("configured account could not reuse its local password")
	}
	if _, err := localPassword(t.TempDir(), true); err == nil {
		t.Fatal("missing password of configured account must not be replaced")
	}
}
