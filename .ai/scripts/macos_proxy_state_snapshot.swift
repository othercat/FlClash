import Foundation
import SystemConfiguration

private func enabled(_ proxies: [String: Any], _ key: CFString) -> Bool {
    if let value = proxies[key as String] as? NSNumber {
        return value.boolValue
    }
    return false
}

private func stringValue(_ proxies: [String: Any], _ key: CFString) -> String {
    proxies[key as String] as? String ?? ""
}

private func integerValue(_ proxies: [String: Any], _ key: CFString) -> Int? {
    (proxies[key as String] as? NSNumber)?.intValue
}

private func isLoopback(_ value: String) -> Bool {
    ["127.0.0.1", "localhost", "::1"].contains(value.lowercased())
}

guard let rawProxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
    FileHandle.standardError.write(Data("unable to read system proxy state\n".utf8))
    exit(1)
}

let httpEnabled = enabled(rawProxies, kSCPropNetProxiesHTTPEnable)
let httpsEnabled = enabled(rawProxies, kSCPropNetProxiesHTTPSEnable)
let socksEnabled = enabled(rawProxies, kSCPropNetProxiesSOCKSEnable)
let pacEnabled = enabled(rawProxies, kSCPropNetProxiesProxyAutoConfigEnable)

let httpHost = stringValue(rawProxies, kSCPropNetProxiesHTTPProxy)
let httpsHost = stringValue(rawProxies, kSCPropNetProxiesHTTPSProxy)
let socksHost = stringValue(rawProxies, kSCPropNetProxiesSOCKSProxy)
let httpPort = integerValue(rawProxies, kSCPropNetProxiesHTTPPort)
let httpsPort = integerValue(rawProxies, kSCPropNetProxiesHTTPSPort)
let socksPort = integerValue(rawProxies, kSCPropNetProxiesSOCKSPort)

let enabledHostsAreLoopback = (!httpEnabled || isLoopback(httpHost))
    && (!httpsEnabled || isLoopback(httpsHost))
    && (!socksEnabled || isLoopback(socksHost))
let enabledPortsMatch = (!httpEnabled || httpPort != nil)
    && (!httpsEnabled || httpsPort == httpPort)
    && (!socksEnabled || socksPort == httpPort)

print("http_enable=\(httpEnabled)")
print("https_enable=\(httpsEnabled)")
print("socks_enable=\(socksEnabled)")
print("pac_enable=\(pacEnabled)")
print("enabled_hosts_are_loopback=\(enabledHostsAreLoopback)")
print("enabled_ports_match=\(enabledPortsMatch)")
