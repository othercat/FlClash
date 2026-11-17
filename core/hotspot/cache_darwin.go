package hotspot

import (
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"time"
)

type cachedCommand struct {
	files   []os.FileInfo
	network string
	value   string
	readAt  time.Time
}

// Each platform is serialized by Manager.mu. Cache only successful reads;
// stat/command failures must never keep a stale enabled sharing preference.
type commandReadCache struct {
	entries map[string]cachedCommand
	now     func() time.Time
	run     func(string, ...string) (string, error)
}

func (c *commandReadCache) read(paths []string, network string, maxAge time.Duration, args ...string) (string, error) {
	key := strings.Join(args, "\x00")
	files := make([]os.FileInfo, len(paths))
	for i, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			delete(c.entries, key)
			return "", err
		}
		files[i] = info
	}
	now := time.Now()
	if c.now != nil {
		now = c.now()
	}
	previous, ok := c.entries[key]
	age := now.Sub(previous.readAt)
	if ok && previous.network == network && sameFileVersions(previous.files, files) && (maxAge == 0 || (age >= 0 && age < maxAge)) {
		return previous.value, nil
	}
	run := c.run
	if run == nil {
		run = command
	}
	value, err := run("", args...)
	if err != nil {
		delete(c.entries, key)
		return "", err
	}
	if c.entries == nil || len(c.entries) >= 16 {
		c.entries = make(map[string]cachedCommand)
	}
	c.entries[key] = cachedCommand{files: files, network: network, value: value, readAt: now}
	return value, nil
}

func sameFileVersions(a, b []os.FileInfo) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !os.SameFile(a[i], b[i]) || a[i].Size() != b[i].Size() || a[i].Mode() != b[i].Mode() || !a[i].ModTime().Equal(b[i].ModTime()) {
			return false
		}
	}
	return true
}

// Read identity, flags and addresses natively every active check. Only the
// external bridge-members query is cached, also with a bounded maximum age.
func interfaceVersion() (string, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	var version []string
	for _, iface := range interfaces {
		addresses, err := iface.Addrs()
		if err != nil {
			return "", err
		}
		var ips []string
		for _, address := range addresses {
			ips = append(ips, address.String())
		}
		sort.Strings(ips)
		version = append(version, fmt.Sprintf("%d:%s:%d:%s", iface.Index, iface.Name, iface.Flags, strings.Join(ips, ",")))
	}
	sort.Strings(version)
	return strings.Join(version, "\n"), nil
}
