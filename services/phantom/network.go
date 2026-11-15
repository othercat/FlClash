package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// Only the vendor bootstrap host can use this CONNECT listener. TLS to the
// official service terminates inside the official library.
func startNetwork(ctx context.Context) (string, string, error) {
	udp, err := net.ListenPacket("udp4", loopback+":0")
	if err != nil {
		return "", "", err
	}
	tcp, err := net.Listen("tcp4", loopback+":0")
	if err != nil {
		udp.Close()
		return "", "", err
	}
	transport := &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{ServerName: "dns.alidns.com", MinVersion: tls.VersionTLS12}, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var last error
		for _, ip := range []string{"223.5.5.5:443", "223.6.6.6:443"} {
			var c net.Conn
			c, last = uplink(ctx, ip)
			if last == nil {
				return c, nil
			}
		}
		return nil, last
	}}
	doh := &http.Client{Timeout: 8 * time.Second, Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	slots := make(chan struct{}, 32)
	go func() {
		for {
			var packet [65535]byte
			n, addr, e := udp.ReadFrom(packet[:])
			if e != nil {
				return
			}
			if n < 12 {
				continue
			}
			select {
			case slots <- struct{}{}:
			default:
				continue
			}
			go func(data []byte, dst net.Addr) {
				defer func() { <-slots }()
				req, e := http.NewRequestWithContext(ctx, "POST", "https://dns.alidns.com/dns-query", strings.NewReader(string(data)))
				if e != nil {
					return
				}
				req.Header.Set("Content-Type", "application/dns-message")
				req.Header.Set("Accept", "application/dns-message")
				res, e := doh.Do(req)
				if e != nil {
					return
				}
				defer res.Body.Close()
				if res.StatusCode != 200 {
					return
				}
				reply, e := io.ReadAll(io.LimitReader(res.Body, 65536))
				if e == nil && len(reply) >= 12 && len(reply) <= 65535 && reply[0] == data[0] && reply[1] == data[1] {
					_, _ = udp.WriteTo(reply, dst)
				}
			}(packet[:n], addr)
		}
	}()
	var cacheMu sync.Mutex
	var cached []string
	var expires time.Time
	resolve := func() ([]string, error) {
		cacheMu.Lock()
		defer cacheMu.Unlock()
		if time.Now().Before(expires) {
			return cached, nil
		}
		req, _ := http.NewRequestWithContext(ctx, "GET", "https://dns.alidns.com/resolve?name="+officialHost+"&type=A", nil)
		res, e := doh.Do(req)
		if e != nil {
			return nil, e
		}
		defer res.Body.Close()
		var data struct {
			Answer []struct {
				Type, TTL int
				Data      string
			}
		}
		if res.StatusCode != 200 || json.NewDecoder(io.LimitReader(res.Body, 65536)).Decode(&data) != nil {
			return nil, errors.New("bootstrap DNS unavailable")
		}
		var ips []string
		ttl := 300
		for _, v := range data.Answer {
			ip, e := netip.ParseAddr(v.Data)
			if v.Type == 1 && e == nil && ip.Is4() && ip.IsGlobalUnicast() && !ip.IsPrivate() {
				ips = append(ips, net.JoinHostPort(v.Data, "443"))
				ttl = min(ttl, max(10, v.TTL))
			}
		}
		if len(ips) == 0 {
			return nil, errors.New("empty bootstrap DNS response")
		}
		cached = ips
		expires = time.Now().Add(time.Duration(ttl) * time.Second)
		return ips, nil
	}
	srv := &http.Server{ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 8192, Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != "CONNECT" || req.Host != officialHost+":443" {
			http.Error(w, "forbidden", 403)
			return
		}
		ips, e := resolve()
		if e != nil {
			http.Error(w, "unavailable", 502)
			return
		}
		var upstream net.Conn
		for _, ip := range ips {
			upstream, e = uplink(ctx, ip)
			if e == nil {
				break
			}
		}
		if e != nil {
			http.Error(w, "unavailable", 502)
			return
		}
		defer upstream.Close()
		downstream, buf, e := w.(http.Hijacker).Hijack()
		if e != nil {
			return
		}
		defer downstream.Close()
		_, e = buf.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		if e != nil || buf.Flush() != nil {
			return
		}
		stop := context.AfterFunc(ctx, func() { downstream.Close(); upstream.Close() })
		defer stop()
		go func() {
			_, _ = io.Copy(upstream, buf)
			if t, ok := upstream.(*net.TCPConn); ok {
				t.CloseWrite()
			}
		}()
		_, _ = io.Copy(downstream, upstream)
	})}
	go func() { _ = srv.Serve(tcp) }()
	go func() { <-ctx.Done(); udp.Close(); srv.Close(); transport.CloseIdleConnections() }()
	return udp.LocalAddr().String(), "http://" + tcp.Addr().String(), nil
}

var ifaceCache struct {
	sync.Mutex
	index int
	until time.Time
}

func physicalIndex(ctx context.Context) (int, error) {
	ifaceCache.Lock()
	defer ifaceCache.Unlock()
	if time.Now().Before(ifaceCache.until) {
		return ifaceCache.index, nil
	}
	index, err := defaultInterface(ctx)
	if err == nil {
		ifaceCache.index = index
		ifaceCache.until = time.Now().Add(15 * time.Second)
	}
	return index, err
}
func uplink(ctx context.Context, address string) (net.Conn, error) {
	idx, err := physicalIndex(ctx)
	if err != nil {
		return nil, err
	}
	d := net.Dialer{Timeout: 4 * time.Second, Control: bindInterface(idx)}
	return d.DialContext(ctx, "tcp4", address)
}
