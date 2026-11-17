//go:build !darwin

package hotspot

func newPlatform() platform { return nil }

func newRouterPlatform() platform { return nil }
