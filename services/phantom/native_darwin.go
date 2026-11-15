package main

/*
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
typedef int32_t (*strfn)(const char*);
typedef int32_t (*startfn)(uint16_t);
static void* library;
static void (*stopfn)(void),(*endfn)(void);
static int begin_core(const char *path,const char *config,int port) {
 if (!library) library=dlopen(path, RTLD_LOCAL|RTLD_NOW);
 if (!library) return 1;
 strfn setup=(strfn)dlsym(library,"nfx_setup"), begin=(strfn)dlsym(library,"nfx_begin_file");
 startfn start=(startfn)dlsym(library,"nfx_cored_start");
 int32_t (*listening)(void)=dlsym(library,"nfx_cored_listening_port");
 stopfn=dlsym(library,"nfx_cored_stop"); endfn=dlsym(library,"nfx_end");
 if (!setup||!begin||!start||!listening||!stopfn||!endfn) return 2;
 if (setup(NULL)||begin(config)) return 3;
 if (start(port)!=port||listening()!=port) {endfn();return 4;}
 return 0;
}
static void end_core(void){stopfn();endfn();}
*/
import "C"
import (
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

func startCore(assets, config string, port int) (func(), error) {
	exe, e := os.Executable()
	if e != nil {
		return nil, e
	}
	lib := C.CString(filepath.Join(filepath.Dir(filepath.Dir(exe)), "Frameworks", "libnfxcore.dylib"))
	defer C.free(unsafe.Pointer(lib))
	path := C.CString(config)
	defer C.free(unsafe.Pointer(path))
	if C.begin_core(lib, path, C.int(port)) != 0 {
		return nil, errNative
	}
	return func() { C.end_core() }, nil
}
func ordinaryUser() bool { return os.Getuid() != 0 && os.Geteuid() == os.Getuid() }
func defaultInterface(ctx context.Context) (int, error) {
	b, e := exec.CommandContext(ctx, "/sbin/route", "-n", "get", "default").Output()
	if e != nil {
		return 0, e
	}
	for _, line := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == "interface" {
			it, e := net.InterfaceByName(strings.TrimSpace(v))
			if e != nil {
				return 0, e
			}
			return it.Index, nil
		}
	}
	return 0, errors.New("no default network interface")
}
func bindInterface(index int) func(string, string, syscall.RawConn) error {
	return func(_, _ string, rc syscall.RawConn) error {
		var inner error
		e := rc.Control(func(fd uintptr) {
			inner = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, index)
		})
		if e != nil {
			return e
		}
		return inner
	}
}
