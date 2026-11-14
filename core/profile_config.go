package main

import (
	"core/profilecompat"
	"runtime"

	"github.com/metacubex/mihomo/config"
)

func unmarshalProfileConfig(content []byte) (*config.RawConfig, error) {
	if runtime.GOOS == "darwin" || runtime.GOOS == "windows" {
		expanded, err := profilecompat.ExpandDesktop(content)
		if err != nil {
			return nil, err
		}
		content = expanded
	}
	return config.UnmarshalRawConfig(content)
}
