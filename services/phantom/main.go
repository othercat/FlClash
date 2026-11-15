// FPPhantomCore runs only as a child of FlClash. Closing the parent's pipe stops it.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

const loopback = "127.0.0.1"

func randomSecret() (string, error) {
	var raw [32]byte
	_, err := rand.Read(raw[:])
	return base64.RawURLEncoding.EncodeToString(raw[:]), err
}

func startGateway() (net.Listener, map[string]any, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return nil, nil, err
	}
	now := time.Now()
	cert := x509.Certificate{SerialNumber: serial, NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(2, 0, 0), IPAddresses: []net.IP{net.ParseIP(loopback)}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, &cert, &cert, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	pass, err := randomSecret()
	if err != nil {
		return nil, nil, err
	}
	l, err := tls.Listen("tcp4", loopback+":0", &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}})
	if err != nil {
		return nil, nil, err
	}
	pin := sha256.Sum256(der)
	return l, map[string]any{"port": l.Addr().(*net.TCPAddr).Port, "password": pass, "fingerprint": hex.EncodeToString(pin[:])}, nil
}

type service struct {
	mu            sync.RWMutex
	routes        *routes
	state, assets string
	reportMu      sync.Mutex
}

func (s *service) status(state string, count int) {
	s.reportMu.Lock()
	defer s.reportMu.Unlock()
	event := map[string]any{"state": state, "nodes": count, "updated": time.Now().UTC().Format(time.RFC3339)}
	data, _ := json.Marshal(event)
	// The parent consumes status events after the one-time endpoint handshake.
	_ = json.NewEncoder(os.Stdout).Encode(event)
	t, err := os.CreateTemp(s.state, ".status-")
	if err != nil {
		return
	}
	defer os.Remove(t.Name())
	_, err = t.Write(data)
	ce := t.Close()
	if err == nil && ce == nil {
		_ = os.Rename(t.Name(), filepath.Join(s.state, "status.json"))
	}
}
func run(ctx context.Context, state string) error {
	if !filepath.IsAbs(state) || !ordinaryUser() {
		return errors.New("ordinary desktop user required")
	}
	if err := os.MkdirAll(state, 0700); err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	dir := filepath.Dir(exe)
	assets := filepath.Join(dir, "Fishport")
	if runtime.GOOS == "darwin" {
		assets = filepath.Join(filepath.Dir(dir), "Resources", "Fishport")
	}
	svc := &service{state: state, assets: assets}
	l, info, err := startGateway()
	if err != nil {
		return err
	}
	defer l.Close()
	if err = json.NewEncoder(os.Stdout).Encode(info); err != nil {
		return err
	}
	done := make(chan struct{})
	go func() { defer close(done); svc.manage(ctx) }()
	go func() { <-ctx.Done(); _ = l.Close() }()
	slots := make(chan struct{}, 256)
	for {
		c, err := l.Accept()
		if err != nil {
			break
		}
		select {
		case slots <- struct{}{}:
			go func() {
				defer func() { <-slots }()
				defer c.Close()
				svc.mu.RLock()
				r := svc.routes
				svc.mu.RUnlock()
				if r != nil {
					forward(ctx, c, r, info["password"].(string))
				}
			}()
		default:
			_ = c.Close()
		}
	}
	select {
	case <-done:
	case <-time.After(4 * time.Second):
	}
	svc.status("stopped", 0)
	return nil
}
func main() {
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }()
	if err := run(ctx, os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "Fishport desktop helper could not start")
		os.Exit(1)
	}
}

var errNative = errors.New("native-runtime-unavailable")
