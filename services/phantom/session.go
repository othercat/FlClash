package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const officialHost = "rw-api.1hdns.cn"

type apiError struct {
	path string
	code int
}

func (e *apiError) Error() string { return fmt.Sprintf("official %s returned %d", e.path, e.code) }

type panel struct {
	url, token string
	client     *http.Client
}

func (p *panel) call(ctx context.Context, path string, input, output any) error {
	var body io.Reader
	method := "GET"
	if input != nil {
		b, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
		method = "POST"
	}
	req, err := http.NewRequestWithContext(ctx, method, p.url+"/consumer/"+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.token != "" {
		req.Header.Set("Authorization", "Bearer "+p.token)
	}
	res, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		if path == "setup" || path == "unlock" {
			// The official panel wraps an invalid airport login in HTTP 400
			// relay_query_failed. The same code also covers network failures.
			var reason struct{ Error string }
			_ = json.NewDecoder(io.LimitReader(res.Body, 8192)).Decode(&reason)
			switch strings.ToLower(strings.TrimSpace(reason.Error)) {
			case "邮箱或密码错误", "账号或密码错误", "用户名或密码错误", "invalid credentials", "invalid email or password", "invalid username or password":
				return errAccountRejected
			}
			if path == "setup" && res.StatusCode == http.StatusUnauthorized {
				return errAccountRejected
			}
		}
		return &apiError{path, res.StatusCode}
	}
	if output != nil {
		return json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(output)
	}
	return nil
}

type loginResult struct {
	Token     string
	LocalOnly bool `json:"local_only"`
}

func (p *panel) login(ctx context.Context, method string, payload map[string]string) error {
	var result loginResult
	if err := p.call(ctx, method, payload, &result); err != nil {
		return err
	}
	if result.LocalOnly || result.Token == "" {
		return errors.New("online vendor account required")
	}
	p.token = result.Token
	return nil
}

func localPassword(state string, configured bool) (string, error) {
	path := filepath.Join(state, "panel-login")
	b, err := os.ReadFile(path)
	if err == nil && len(b) >= 32 {
		return string(b), nil
	}
	if configured || !errors.Is(err, os.ErrNotExist) {
		return "", errors.New("local account state unavailable")
	}
	value, err := randomSecret()
	if err != nil {
		return "", err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if errors.Is(err, os.ErrExist) {
		return localPassword(state, true)
	}
	if err != nil {
		return "", err
	}
	_, err = f.WriteString(value)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	return value, err
}

func reservePort() (int, error) {
	l, err := net.Listen("tcp4", loopback+":0")
	if err != nil {
		return 0, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	return port, l.Close()
}
func (s *service) session(ctx context.Context, input account, dns, bootstrap string) error {
	control, err := reservePort()
	if err != nil {
		return err
	}
	socks, err := reservePort()
	if err != nil {
		return err
	}
	if socks == control {
		return errors.New("port collision")
	}
	state := filepath.Join(s.state, "cored")
	if err = os.MkdirAll(state, 0700); err != nil {
		return err
	}
	airport, err := os.ReadFile(filepath.Join(s.assets, "airport-id"))
	if err != nil {
		return errNative
	}
	for key, val := range map[string]string{
		"RELAYWAY_CORED_STATE": state, "RELAYWAY_CORED_AIRPORT_ID": strings.TrimSpace(string(airport)), "RELAYWAY_CORED_MW_URL": "https://" + officialHost,
		"RELAYWAY_CORED_DAT_DIR": s.assets, "RELAYWAY_CORED_API_TRANSPORT_BUNDLE_FILE": filepath.Join(s.assets, "api-transport-bundle.b64"),
		"HTTP_PROXY": bootstrap, "HTTPS_PROXY": bootstrap, "http_proxy": bootstrap, "https_proxy": bootstrap,
		"NO_PROXY": "localhost,127.0.0.1", "no_proxy": "localhost,127.0.0.1", "RUST_LOG": "error",
	} {
		if err = os.Setenv(key, val); err != nil {
			return err
		}
	}
	f, err := os.CreateTemp(s.state, ".engine-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	// Nothing goes direct while the first authenticated Phantom route is being selected.
	cfg := map[string]any{"dns": map[string]any{"servers": []string{dns}}, "inbounds": []any{map[string]any{"tag": "socks-in", "listen": loopback, "port": socks, "protocol": "socks", "settings": map[string]any{"udp": false}}},
		"outbounds": []any{map[string]any{"tag": "proxy", "protocol": "blackhole", "settings": map[string]any{}}, map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{}}, map[string]any{"tag": "block", "protocol": "blackhole", "settings": map[string]any{}}},
		"routing":   map[string]any{"rules": []any{}}}
	err = json.NewEncoder(f).Encode(cfg)
	ce := f.Close()
	if err != nil {
		return err
	}
	if ce != nil {
		return ce
	}
	end, err := startCore(s.assets, f.Name(), control)
	if err != nil {
		return err
	}
	defer end()
	client := &http.Client{Timeout: 45 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	p := &panel{url: "http://" + net.JoinHostPort(loopback, strconv.Itoa(control)), client: client}
	var auth struct{ Configured *bool }
	if err = p.call(ctx, "auth-status", nil, &auth); err != nil {
		return err
	}
	if auth.Configured == nil {
		return errors.New("unknown official login state")
	}
	gate, err := localPassword(s.state, *auth.Configured)
	if err != nil {
		return err
	}
	if err = p.authenticate(ctx, s.state, *auth.Configured, input, gate); err != nil {
		return err
	}
	catalog := struct {
		Nodes []struct{ ID, Name, Protocol string }
	}{}
	if err = p.call(ctx, "subscription", nil, &catalog); err != nil {
		return err
	}
	ids := map[string]string{}
	ambiguous := map[string]bool{}
	count := 0
	for _, n := range catalog.Nodes {
		if !strings.EqualFold(n.Protocol, "phantom") || n.ID == "" {
			continue
		}
		ids[n.ID] = n.ID
		count++
		name := strings.TrimSpace(strings.SplitN(n.Name, "|", 2)[0])
		if other := ids[name]; other != "" && other != n.ID {
			ambiguous[name] = true
		} else if name != "" {
			ids[name] = n.ID
		}
	}
	for name := range ambiguous {
		delete(ids, name)
	}
	if count == 0 {
		return errors.New("no subscribed Phantom routes")
	}
	r := newRoutes(ctx, p, ids, gate, socks)
	s.mu.Lock()
	s.routes = r
	s.mu.Unlock()
	s.status("ready", count)
	select {
	case <-ctx.Done():
	case <-r.invalid:
	}
	s.mu.Lock()
	s.routes = nil
	s.mu.Unlock()
	r.cancel()
	return errors.New("engine session ended")
}
