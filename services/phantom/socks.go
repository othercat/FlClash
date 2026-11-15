package main

import (
	"context"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

func readN(c net.Conn, n int) ([]byte, error) {
	b := make([]byte, n)
	_, e := io.ReadFull(c, b)
	return b, e
}
func counted(c net.Conn) ([]byte, error) {
	n, e := readN(c, 1)
	if e != nil {
		return nil, e
	}
	return readN(c, int(n[0]))
}
func address(c net.Conn, t byte) (string, []byte, error) {
	switch t {
	case 1, 4:
		n := 4
		if t == 4 {
			n = 16
		}
		b, e := readN(c, n)
		return net.IP(b).String(), append([]byte{t}, b...), e
	case 3:
		b, e := counted(c)
		if e != nil || len(b) == 0 {
			return "", nil, errors.New("invalid domain")
		}
		return strings.ToLower(strings.TrimSuffix(string(b), ".")), append([]byte{3, byte(len(b))}, b...), nil
	}
	return "", nil, errors.New("unsupported address family")
}

var success = []byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}

func connectUpstream(ctx context.Context, port int, dst []byte) (net.Conn, error) {
	dialer := net.Dialer{Timeout: 5 * time.Second}
	c, e := dialer.DialContext(ctx, "tcp4", net.JoinHostPort(loopback, strconv.Itoa(port)))
	if e != nil {
		return nil, e
	}
	ok := false
	defer func() {
		if !ok {
			c.Close()
		}
	}()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	if _, e = c.Write([]byte{5, 1, 0}); e != nil {
		return nil, e
	}
	b, e := readN(c, 2)
	if e != nil || b[0] != 5 || b[1] != 0 {
		return nil, errors.New("vendor SOCKS greeting failed")
	}
	if _, e = c.Write(append([]byte{5, 1, 0}, dst...)); e != nil {
		return nil, e
	}
	hdr, e := readN(c, 4)
	if e != nil || hdr[0] != 5 || hdr[1] != 0 || hdr[2] != 0 {
		return nil, errors.New("vendor route unavailable")
	}
	if _, _, e = address(c, hdr[3]); e != nil {
		return nil, e
	}
	if _, e = readN(c, 2); e != nil {
		return nil, e
	}
	c.SetDeadline(time.Time{})
	ok = true
	return c, nil
}
func forward(ctx context.Context, c net.Conn, r *routes, secret string) {
	c.SetDeadline(time.Now().Add(8 * time.Second))
	g, e := readN(c, 2)
	if e != nil || g[0] != 5 {
		return
	}
	methods, e := readN(c, int(g[1]))
	if e != nil {
		return
	}
	supported := false
	for _, m := range methods {
		if m == 2 {
			supported = true
		}
	}
	if !supported {
		c.Write([]byte{5, 255})
		return
	}
	if _, e = c.Write([]byte{5, 2}); e != nil {
		return
	}
	g, e = readN(c, 1)
	if e != nil || g[0] != 1 {
		return
	}
	name, e := counted(c)
	if e != nil {
		return
	}
	pass, e := counted(c)
	if e != nil {
		return
	}
	id, ok := r.nodes[string(name)]
	if !ok || subtle.ConstantTimeCompare(pass, []byte(secret)) != 1 {
		c.Write([]byte{1, 1})
		return
	}
	c.Write([]byte{1, 0})
	h, e := readN(c, 4)
	if e != nil || h[0] != 5 || h[1] != 1 || h[2] != 0 {
		return
	}
	host, addr, e := address(c, h[3])
	if e != nil {
		return
	}
	port, e := readN(c, 2)
	if e != nil {
		return
	}
	if ip := net.ParseIP(host); (ip != nil && (ip.IsLoopback() || ip.IsUnspecified())) || host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return
	}
	dst := append(addr, port...)
	p := binary.BigEndian.Uint16(port)
	test := host == "www.gstatic.com" && (p == 80 || p == 443)
	c.SetDeadline(time.Time{})
	if !test {
		if _, e = c.Write(success); e != nil {
			return
		}
	}
	timeout := 105 * time.Second
	if test {
		timeout = 630 * time.Second
	}
	wait, cancel := context.WithTimeout(ctx, timeout)
	e = r.admit(wait, id, test)
	cancel()
	if e != nil {
		return
	}
	held := true
	defer func() {
		if held {
			r.pinned()
		}
	}()
	out, e := connectUpstream(r.ctx, r.port, dst)
	if e != nil {
		return
	}
	defer out.Close()
	if test {
		if _, e = c.Write(success); e != nil {
			return
		}
	}
	stop := context.AfterFunc(r.ctx, func() { c.Close(); out.Close() })
	defer stop()
	go func() {
		_, _ = io.Copy(out, c)
		if t, ok := out.(*net.TCPConn); ok {
			t.CloseWrite()
		}
	}()
	// A SOCKS success alone does not pin the official route. Wait for actual
	// upstream data before another request is allowed to change the active node.
	out.SetReadDeadline(time.Now().Add(14 * time.Second))
	var first [32768]byte
	n, e := out.Read(first[:])
	if n == 0 {
		return
	}
	if _, err := c.Write(first[:n]); err != nil {
		return
	}
	out.SetReadDeadline(time.Time{})
	r.pinned()
	held = false
	if e == nil {
		_, _ = io.Copy(c, out)
	}
}
