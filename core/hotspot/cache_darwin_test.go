package hotspot

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCommandCacheInvalidatesSharingChangesAndReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sharing.plist")
	write := func(path, value string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(path, "on")
	commands := 0
	c := commandReadCache{run: func(string, ...string) (string, error) {
		commands++
		b, err := os.ReadFile(path)
		return string(b), err
	}}
	read := func(want string) {
		t.Helper()
		got, err := c.read([]string{path}, "", 0, "plutil", "NAT.Enabled")
		if err != nil || got != want {
			t.Fatalf("cached preference=%q, err=%v, want=%q", got, err, want)
		}
	}
	for i := 0; i < 12; i++ {
		read("on")
	}
	if commands != 1 {
		t.Fatalf("unchanged preference ran %d commands", commands)
	}
	write(path, "off")
	read("off")
	info, _ := os.Stat(path)
	other := path + ".new"
	write(other, "new")
	if err := os.Chtimes(other, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(other, path); err != nil {
		t.Fatal(err)
	}
	read("new") // same size/mtime but another inode
	if commands != 3 {
		t.Fatal("sharing update/replacement was not detected")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if value, err := c.read([]string{path}, "", 0, "plutil", "NAT.Enabled"); err == nil || value != "" {
		t.Fatal("missing preference kept stale sharing enabled")
	}
}

func TestCommandCacheTopologyAgeAndFailures(t *testing.T) {
	now := time.Unix(1000, 0)
	commands := 0
	fail := false
	c := commandReadCache{now: func() time.Time { return now }, run: func(string, ...string) (string, error) {
		commands++
		if fail {
			return "", errors.New("temporary read error")
		}
		return "member: ap1", nil
	}}
	read := func(network string) error {
		_, err := c.read(nil, network, 30*time.Second, "ifconfig", "bridge100")
		return err
	}
	for i := 0; i < 6; i++ {
		if err := read("interfaces1"); err != nil {
			t.Fatal(err)
		}
		now = now.Add(5 * time.Second)
	}
	if commands != 1 {
		t.Fatal("bridge membership repeatedly spawned a process")
	}
	if err := read("interfaces1"); err != nil || commands != 2 {
		t.Fatal("membership-only changes have no bounded refresh")
	}
	if err := read("interfaces2"); err != nil || commands != 3 {
		t.Fatal("interface identity/flags/address changes did not invalidate")
	}
	fail = true
	if read("interfaces3") == nil || read("interfaces3") == nil || commands != 5 {
		t.Fatal("failed query was cached or returned stale members")
	}
	fail = false
	if err := read("interfaces3"); err != nil || commands != 6 {
		t.Fatal("query did not recover after read failure")
	}
}
