//go:build darwin || windows

package main

import (
	"core/routeiface"

	"github.com/metacubex/mihomo/listener/sing_tun"
)

func init() {
	// Install once, below the TUN listener lifecycle. Its auto-detect flag and
	// loop protection still own whether and how this finder is used.
	sing_tun.DefaultInterfaceFinder = routeiface.New(sing_tun.DefaultInterfaceFinder)
}
