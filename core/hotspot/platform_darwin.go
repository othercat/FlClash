package hotspot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/mihomo/log"
	"go4.org/netipx"
	"golang.org/x/sys/unix"
)

type darwinPlatform struct {
	anchor          string
	installed       bool
	link            link
	policy          string
	forwarding      forwardingRecovery
	nextPolicyRetry time.Time
	pf              pfOperations
	router          bool
	lease           *pfLease
	reads           commandReadCache
	policyVersion   pfPolicyVersion
	versionValid    bool
}

// Keep the privileged operations injectable for recovery fault tests. Tests
// never reset the live host's forwarding, PF rules, TUN or application.
type pfOperations struct {
	command func(string, ...string) (string, error)
	hooks   func(string) (bool, error)
	ensure  func(string, byte) error
	retire  func(link) error
	version func(string) (pfPolicyVersion, error)
}

func newPlatform() platform {
	p := &darwinPlatform{anchor: fmt.Sprintf("flclash-hotspot-%d", os.Getpid())}
	p.pf = pfOperations{command: command, hooks: ownAnchorsPresent, ensure: ensureAnchor, retire: discardClientStates, version: readPFPolicyVersion}
	p.forwarding = forwardingRecovery{
		read: func() (uint32, error) { return unix.SysctlUint32("net.inet.ip.forwarding") },
		write: func() error {
			// The user can switch system sharing off between detection and
			// repair. Recheck its explicit preference immediately before writing.
			enabled, err := command("", "/usr/bin/plutil", "-extract", "NAT.Enabled", "raw", "-o", "-", "/Library/Preferences/SystemConfiguration/com.apple.nat.plist")
			if err != nil || (strings.TrimSpace(enabled) != "1" && strings.TrimSpace(enabled) != "true") {
				return errors.New("Internet Sharing is no longer enabled")
			}
			_, err = command("", "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1")
			return err
		},
		now: time.Now,
	}
	return p
}

func newRouterPlatform() platform {
	p := newPlatform().(*darwinPlatform)
	p.router = true
	p.anchor = fmt.Sprintf("flclash-router-%d", os.Getpid())
	p.lease = newPFLease()
	return p
}

func (p *darwinPlatform) detectRouter(env Environment) (link, error) {
	tun, err := net.InterfaceByName(env.TunDevice)
	if err != nil || tun.Flags&net.FlagUp == 0 {
		return link{}, errors.New("tunRequired")
	}
	addresses, err := tun.Addrs()
	if err != nil {
		return link{}, fmt.Errorf("%w: read TUN addresses", errPlatformTemporary)
	}
	ready4, ready6 := false, false
	for _, a := range addresses {
		prefix, err := netip.ParsePrefix(a.String())
		if err != nil {
			continue
		}
		ready4 = ready4 || prefix.Addr() == env.TunAddress
		ready6 = ready6 || prefix.Addr() == env.Tun6Address
	}
	if !ready4 {
		return link{}, errors.New("tunRequired")
	}
	choices, err := routerInterfaces()
	if err != nil {
		return link{}, fmt.Errorf("%w: read LAN interfaces", errPlatformTemporary)
	}
	preferred := ""
	if env.RouterAddress == "" {
		preferred, err = defaultRouteInterface()
		// Preserve the existing path when native RIB data is ambiguous or
		// unsupported. Never guess a different LAN in that case.
		if err != nil {
			out, _ := command("", "/sbin/route", "-n", "get", "default")
			for _, row := range strings.Split(out, "\n") {
				fields := strings.Fields(row)
				if len(fields) == 2 && fields[0] == "interface:" {
					preferred = fields[1]
				}
			}
		}
	}
	l, err := selectRouterLink(env, choices, preferred)
	if err != nil {
		return link{}, err
	}
	if !ready6 {
		l.disableIPv6()
	}
	l.StateLabel = p.anchor
	if addresses, err := net.InterfaceAddrs(); err == nil {
		var hosts []string
		for _, a := range addresses {
			hosts = append(hosts, a.String())
		}
		sort.Strings(hosts)
		l.HostAddresses = strings.Join(hosts, " ")
	}
	return l, nil
}

func command(input string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, args[0], args[1:]...)
	if input != "" {
		c.Stdin = strings.NewReader(input)
	}
	var stdout, stderr bytes.Buffer
	c.Stdout = &stdout
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		return "", fmt.Errorf("%s: %w: %s", args[0], err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

func (p *darwinPlatform) detect(env Environment) (link, error) {
	if os.Geteuid() != 0 {
		return link{}, errors.New("permissionRequired")
	}
	if p.router {
		return p.detectRouter(env)
	}
	// Extract only the two public sharing fields. The full preferences plist
	// also contains NSData (the hotspot password), which cannot become JSON.
	const preferences = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"
	nat, err := p.reads.read([]string{preferences}, "", 0, "/usr/bin/plutil", "-extract", "NAT.Enabled", "raw", "-o", "-", preferences)
	if err != nil {
		return link{}, fmt.Errorf("%w: read Internet Sharing preference", errPlatformTemporary)
	}
	if enabled := strings.TrimSpace(nat); enabled != "1" && enabled != "true" {
		return link{}, errors.New("sharingRequired")
	}
	device, err := p.reads.read([]string{preferences}, "", 0, "/usr/bin/plutil", "-extract", "NAT.SharingDevices.0", "raw", "-o", "-", preferences)
	if err != nil {
		return link{}, fmt.Errorf("%w: read shared interface", errPlatformTemporary)
	}
	if strings.TrimSpace(device) == "" {
		return link{}, errors.New("sharingRequired")
	}
	b, err := p.reads.read([]string{"/etc/bootpd.plist"}, "", 0, "/usr/bin/plutil", "-convert", "json", "-o", "-", "/etc/bootpd.plist")
	if err != nil {
		return link{}, fmt.Errorf("%w: read sharing subnet", errPlatformTemporary)
	}
	var subnets struct {
		Subnets []struct {
			Creator   string `json:"_creator"`
			Interface string
			Router    string `json:"dhcp_router"`
		}
	}
	if json.Unmarshal([]byte(b), &subnets) != nil {
		return link{}, errors.New("sharingRequired")
	}
	var links []link
	var hostAddresses []string
	networkVersion, networkErr := interfaceVersion()
	if addresses, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addresses {
			hostAddresses = append(hostAddresses, a.String())
		}
		sort.Strings(hostAddresses)
	}
	for _, s := range subnets.Subnets {
		if s.Creator != "com.apple.NetworkSharing" || !bridgeName.MatchString(s.Interface) {
			continue
		}
		iface, err := net.InterfaceByName(s.Interface)
		if err != nil || iface.Flags&net.FlagUp == 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		// Local DNS packets can retain the Wi-Fi member's receive interface;
		// forwarded data is presented on the Internet Sharing bridge.
		var members []string
		var out string
		if networkErr == nil {
			out, err = p.reads.read([]string{preferences, "/etc/bootpd.plist"}, networkVersion, 30*time.Second, "/sbin/ifconfig", s.Interface)
		} else {
			out, err = command("", "/sbin/ifconfig", s.Interface)
		}
		if err == nil {
			for _, line := range strings.Split(out, "\n") {
				fields := strings.Fields(line)
				if len(fields) > 1 && fields[0] == "member:" && memberName.MatchString(fields[1]) {
					members = append(members, fields[1])
				}
			}
			sort.Strings(members)
		}
		var v6 []string
		var v6Networks []string
		for _, a := range addresses {
			prefix, err := netip.ParsePrefix(a.String())
			if err != nil || !prefix.Addr().Is6() {
				continue
			}
			ip := prefix.Addr()
			if ip.IsLinkLocalUnicast() {
				ip = ip.WithZone(s.Interface)
			}
			v6 = append(v6, ip.String())
			v6Networks = append(v6Networks, prefix.Masked().String())
		}
		for _, a := range addresses {
			prefix, err := netip.ParsePrefix(a.String())
			if err != nil || !prefix.Addr().Is4() || prefix.Addr().String() != s.Router {
				continue
			}
			links = append(links, link{Interface: s.Interface, Address: prefix.Addr(), Network: prefix.Masked(), IPv6: strings.Join(v6, " "), IPv6Networks: strings.Join(v6Networks, " "), HostAddresses: strings.Join(hostAddresses, " "), DNSInterfaces: strings.Join(members, " "), TunDevice: env.TunDevice, TunAddress: env.TunAddress})
		}
	}
	if len(links) != 1 {
		return link{}, errors.New("sharingRequired")
	}
	info, err := command("", "/sbin/pfctl", "-s", "info")
	if err != nil || !strings.Contains(info, "Status: Enabled") {
		return link{}, fmt.Errorf("%w: PF is not currently available", errPlatformTemporary)
	}
	return links[0], nil
}

func (p *darwinPlatform) install(l link, port int) error {
	raw, err := rules(l, port)
	if err != nil {
		return err
	}
	if p.router {
		if err := p.lease.ensure(); err != nil {
			return err
		}
	}
	if err := p.ensureForwarding(); err != nil {
		return err
	}
	samePath := p.installed && p.link.sameForwardingPath(l)
	if !p.installed {
		if err = p.cleanOrphans(); err != nil {
			return err
		}
	}
	// Validate without loading, then atomically replace only our own child
	// ruleset. Root calls are inserted individually, never by reloading PF.
	if _, err = p.pf.command(raw, "/sbin/pfctl", "-n", "-a", p.anchor, "-f", "-"); err != nil {
		return err
	}
	if _, err = p.pf.command(raw, "/sbin/pfctl", "-a", p.anchor, "-f", "-"); err != nil {
		return err
	}
	p.installed = true
	p.link = l
	if err = p.pf.ensure(p.anchor, 0); err != nil {
		return err
	}
	if err = p.pf.ensure(p.anchor, 8); err != nil {
		return err
	}
	// Learn a native generation only around a verified nonempty text policy.
	// A concurrent external flush must not become the healthy baseline.
	p.versionValid = false
	var before pfPolicyVersion
	var beforeErr error
	if p.pf.version != nil {
		before, beforeErr = p.pf.version(p.anchor)
	}
	policy, err := p.readPolicy()
	if err != nil {
		return err
	}
	// An external all-flush can race the child load and root-hook repair.
	// Never learn an empty child as a new healthy policy baseline.
	if !completePolicy(policy) {
		return errors.New("hotspot PF rules disappeared during installation")
	}
	if p.pf.version != nil && beforeErr == nil {
		after, err := p.pf.version(p.anchor)
		if err == nil {
			if before != after || !after.complete() {
				return errors.New("hotspot PF generation changed during installation")
			}
			p.policyVersion, p.versionValid = after, true
		}
	}
	p.policy = policy
	// Internet Sharing owns PF's enable reference. We neither enable nor
	// disable PF, and cannot leave a leaked enable token after a crash.
	if !samePath {
		return p.pf.retire(l)
	}
	return nil
}

func (p *darwinPlatform) ensureForwarding() error {
	if p.router {
		// Explicit PF return paths cover both families, without changing host
		// IPv6 router/RA settings or either global forwarding sysctl.
		return nil
	}
	recovered, err := p.forwarding.ensure()
	if recovered {
		log.Warnln("[Hotspot] Restored IPv4 forwarding after an external reset; Internet Sharing and TUN remain enabled")
	}
	return err
}

func (p *darwinPlatform) readPolicy() (string, error) {
	filter, err := p.pf.command("", "/sbin/pfctl", "-a", p.anchor, "-sr")
	if err != nil {
		return "", err
	}
	redirect, err := p.pf.command("", "/sbin/pfctl", "-a", p.anchor, "-sn")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(filter) + "\n--RDR--\n" + strings.TrimSpace(redirect), nil
}

func completePolicy(policy string) bool {
	parts := strings.SplitN(policy, "\n--RDR--\n", 2)
	return len(parts) == 2 && strings.TrimSpace(parts[0]) != "" && strings.TrimSpace(parts[1]) != ""
}

func (p *darwinPlatform) maintain(l link, port int) error {
	if p.router {
		if err := p.lease.ensure(); err != nil {
			return err
		}
	}
	if err := p.ensureForwarding(); err != nil {
		return err
	}
	hooks, err := p.pf.hooks(p.anchor)
	if err != nil {
		return err
	}
	healthy := false
	if p.versionValid && p.pf.version != nil {
		version, readErr := p.pf.version(p.anchor)
		if readErr == nil {
			healthy = version.complete() && version == p.policyVersion
		} else {
			// On an unsupported/failed native read, retain the old full check.
			// Never trust stale tickets or close working DNS listeners.
			policy, err := p.readPolicy()
			if err != nil {
				return err
			}
			healthy = completePolicy(policy) && policy == p.policy
		}
	} else {
		policy, err := p.readPolicy()
		if err != nil {
			return err
		}
		healthy = completePolicy(policy) && policy == p.policy
	}
	if p.installed && p.link == l && hooks && healthy {
		return nil
	}
	if time.Now().Before(p.nextPolicyRetry) {
		return errors.New("hotspot PF recovery is cooling down after a recent attempt")
	}
	p.nextPolicyRetry = time.Now().Add(10 * time.Second)
	tag := "Hotspot"
	if p.router {
		tag = "SoftRouter"
	}
	log.Warnln("[%s] Restoring own gateway rules after an external PF change; DNS listener remains open", tag)
	return p.install(l, port)
}

func (p *darwinPlatform) remove() error {
	if !p.installed {
		return p.lease.close()
	}
	// Emptying only the child detaches interception immediately. Keep unrelated
	// root calls, rules, and every PF state intact.
	if _, err := command("\n", "/sbin/pfctl", "-a", p.anchor, "-f", "-"); err != nil {
		return err
	}
	var errs []error
	for _, action := range []byte{8, 0} {
		if err := removeAnchor(p.anchor, action); err != nil {
			errs = append(errs, err)
		}
	}
	if err := discardClientStates(p.link); err != nil {
		errs = append(errs, err)
	}
	if len(errs) == 0 {
		if err := p.lease.close(); err != nil {
			return err
		}
		p.installed = false
		p.policy = ""
		p.versionValid = false
	}
	return errors.Join(errs...)
}

func (p *darwinPlatform) cleanOrphans() error {
	f, err := os.OpenFile("/dev/pf", os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	names := make(map[string]bool)
	for _, action := range []byte{0, 8} {
		list, err := rootCalls(f.Fd(), action)
		if err != nil {
			return err
		}
		for _, r := range list {
			names[callName(r)] = true
		}
	}
	for name := range names {
		prefix := "flclash-hotspot-"
		if p.router {
			prefix = "flclash-router-"
		}
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimPrefix(name, prefix))
		if err != nil || pid <= 1 || unix.Kill(pid, 0) != unix.ESRCH {
			continue
		}
		if _, err = command("\n", "/sbin/pfctl", "-a", name, "-f", "-"); err != nil {
			return err
		}
		for _, action := range []byte{8, 0} {
			if err = removeAnchor(name, action); err != nil {
				return err
			}
		}
	}
	return nil
}

// Retire only hotspot client states, never host-originated proxy/VPN states.
// PF looks up state before new rules, so the old Internet Sharing rtable and
// this mode's old route-to must be retired when the user switches the mode.
func discardClientStates(l link) error {
	if l.Router {
		// Data forwarding is stateless, and the DNS backend port is stable.
		// Do not flush the LAN: it also carries host SMB/SSH/VPN connections.
		return nil
	}
	var b netipx.IPSetBuilder
	b.AddPrefix(l.Network)
	b.Remove(l.Address)
	set, err := b.IPSet()
	if err != nil {
		return err
	}
	var sources []string
	for _, prefix := range set.Prefixes() {
		sources = append(sources, prefix.String())
	}
	// Link-local IPv6 is shared by several interfaces. Select only neighbor
	// addresses on this hotspot, instead of ever killing fe80::/10 globally.
	if out, err := command("", "/usr/sbin/ndp", "-an"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			fields := strings.Fields(line)
			if len(fields) < 3 || fields[2] != l.Interface {
				continue
			}
			ip, err := netip.ParseAddr(fields[0])
			if err != nil || !ip.Is6() {
				continue
			}
			if strings.Contains(" "+l.IPv6+" ", " "+ip.String()+" ") {
				continue
			}
			ip = ip.WithZone("")
			sources = append(sources, ip.String())
		}
	}
	for _, source := range sources {
		if _, err := command("", "/sbin/pfctl", "-k", source); err != nil {
			return err
		}
	}
	return nil
}
