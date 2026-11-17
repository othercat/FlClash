package main

import (
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/listener"
)

func TestProxyBindAddress(t *testing.T) {
	for _, host := range []string{
		"", " ", "127.0.0.1", "127.0.0.2", "::1", "[::1]",
		"::ffff:127.0.0.1", "localhost", " LOCALHOST ",
	} {
		t.Run("LAN enabled "+host, func(t *testing.T) {
			if got := proxyBindAddress(host, true); got != "*" {
				t.Fatalf("got %q, want wildcard LAN binding", got)
			}
		})
	}
	for _, host := range []string{"*", "0.0.0.0", "192.168.2.1", "[fd00::1]"} {
		t.Run("explicit binding "+host, func(t *testing.T) {
			if got := proxyBindAddress(host, true); got != host {
				t.Fatalf("got %q, want explicit binding %q", got, host)
			}
		})
	}
	for _, host := range []string{"", "*", "0.0.0.0", "192.168.2.1", "[::]"} {
		t.Run("LAN disabled "+host, func(t *testing.T) {
			if got := proxyBindAddress(host, false); got != "127.0.0.1" {
				t.Fatalf("got %q, want loopback-only binding", got)
			}
		})
	}
}

func TestLANProxyLiveUpdates(t *testing.T) {
	previousConfig, previousRunning := currentConfig, isRunning
	previousAllowLan, previousBind := listener.AllowLan(), listener.BindAddress()
	previousGeoUpdate := updater.GeoAutoUpdate()
	t.Cleanup(func() {
		currentConfig, isRunning = previousConfig, previousRunning
		listener.SetAllowLan(previousAllowLan)
		listener.SetBindAddress(previousBind)
		updater.SetGeoAutoUpdate(previousGeoUpdate)
	})
	updater.SetGeoAutoUpdate(false)

	for _, host := range []string{"127.0.0.1", "[::1]", "*", "192.168.2.1"} {
		t.Run(host, func(t *testing.T) {
			// All listener ports and TUN remain disabled in this isolated process.
			general := &config.General{}
			general.BindAddress = host
			currentConfig = &config.Config{General: general}
			isRunning = true
			for _, enabled := range []bool{false, true, false, true} {
				expectedGeneral := *general
				expectedGeneral.AllowLan = enabled
				updateConfig(&UpdateParams{AllowLan: &enabled})
				if general.AllowLan != enabled || listener.AllowLan() != enabled {
					t.Fatalf("LAN update %v did not reach config and listener", enabled)
				}
				if got, want := listener.BindAddress(), proxyBindAddress(host, enabled); got != want {
					t.Fatalf("LAN update %v binds %q, want %q", enabled, got, want)
				}
				if !reflect.DeepEqual(*general, expectedGeneral) {
					t.Fatal("LAN update changed unrelated general configuration")
				}
			}
			// A port/mode update without an explicit LAN flag keeps its value.
			updateConfig(&UpdateParams{})
			if !general.AllowLan || !listener.AllowLan() {
				t.Fatal("an unrelated update disabled LAN access")
			}
			if general.BindAddress != host {
				t.Fatal("LAN toggles overwrote the profile's explicit binding")
			}
		})
	}
}
