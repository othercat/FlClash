package main

import (
	"context"
	"errors"
	"fmt"
	"math/bits"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

var systemDLL = syscall.NewLazyDLL("kernel32.dll")
var securityDLL = syscall.NewLazyDLL("advapi32.dll")
var loadedLibrary syscall.Handle

func startCore(assets, config string, port int) (func(), error) {
	if loadedLibrary == 0 {
		path, e := syscall.UTF16PtrFromString(filepath.Join(assets, "nfxcore.dll"))
		if e != nil {
			return nil, e
		}
		// Load only from the packaged DLL's directory and Windows System32.
		h, _, errno := systemDLL.NewProc("LoadLibraryExW").Call(uintptr(unsafe.Pointer(path)), 0, 0x100|0x800)
		if h == 0 {
			return nil, fmt.Errorf("%w-load-%d", errNative, errno.(syscall.Errno))
		}
		loadedLibrary = syscall.Handle(h)
	}
	symbols := make(map[string]uintptr)
	for _, name := range []string{"nfx_setup", "nfx_begin_file", "nfx_cored_start", "nfx_cored_listening_port", "nfx_cored_stop", "nfx_end"} {
		p, e := syscall.GetProcAddress(loadedLibrary, name)
		if e != nil {
			return nil, fmt.Errorf("%w-missing-%s", errNative, name)
		}
		symbols[name] = p
	}
	path, e := syscall.BytePtrFromString(config)
	if e != nil {
		return nil, e
	}
	call := func(n string, a ...uintptr) int32 { ret, _, _ := syscall.SyscallN(symbols[n], a...); return int32(ret) }
	if code := call("nfx_setup", 0); code != 0 {
		return nil, fmt.Errorf("%w-setup-%d", errNative, code)
	}
	if code := call("nfx_begin_file", uintptr(unsafe.Pointer(path))); code != 0 {
		return nil, fmt.Errorf("%w-engine-%d", errNative, code)
	}
	if code := call("nfx_cored_start", uintptr(port)); code != int32(port) || call("nfx_cored_listening_port") != int32(port) {
		call("nfx_end")
		return nil, fmt.Errorf("%w-control-%d", errNative, code)
	}
	return func() { call("nfx_cored_stop"); call("nfx_end") }, nil
}
func ordinaryUser() bool {
	var token syscall.Token
	proc, err := syscall.GetCurrentProcess()
	if err != nil || syscall.OpenProcessToken(proc, syscall.TOKEN_QUERY, &token) != nil {
		return false
	}
	defer token.Close()
	var elevated, size uint32
	ok, _, _ := securityDLL.NewProc("GetTokenInformation").Call(uintptr(token), 20, uintptr(unsafe.Pointer(&elevated)), 4, uintptr(unsafe.Pointer(&size)))
	return ok != 0 && elevated == 0
}
func defaultInterface(ctx context.Context) (int, error) {
	// A full TUN often installs two /1 routes. Select the active physical IPv4
	// default using both Windows route and interface metrics.
	ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	command := "$m=@{}; Get-NetIPInterface -AddressFamily IPv4 | ForEach-Object {$m[$_.InterfaceIndex]=$_.InterfaceMetric}; (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore | Where-Object {$_.NextHop -ne '0.0.0.0'} | Sort-Object { $_.RouteMetric + $m[$_.InterfaceIndex] } | Select-Object -First 1).InterfaceIndex"
	c := exec.CommandContext(ctx, ps, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	b, e := c.Output()
	if e != nil {
		return 0, e
	}
	index, e := strconv.Atoi(strings.TrimSpace(string(b)))
	if e != nil || index <= 0 {
		return 0, errors.New("no physical IPv4 default route")
	}
	return index, nil
}
func bindInterface(index int) func(string, string, syscall.RawConn) error {
	return func(_, _ string, rc syscall.RawConn) error {
		var inner error
		e := rc.Control(func(fd uintptr) {
			inner = syscall.SetsockoptInt(syscall.Handle(fd), syscall.IPPROTO_IP, 31, int(bits.ReverseBytes32(uint32(index))))
		})
		if e != nil {
			return e
		}
		return inner
	}
}
