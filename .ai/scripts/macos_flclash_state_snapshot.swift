import AppKit
import CoreGraphics
import Foundation

private func boolValue(
    _ dictionary: [String: Any],
    key: String,
    default defaultValue: Bool
) -> Bool {
    dictionary[key] as? Bool ?? defaultValue
}

private func dictionaryValue(
    _ dictionary: [String: Any],
    key: String
) -> [String: Any] {
    dictionary[key] as? [String: Any] ?? [:]
}

let bundleID = CommandLine.arguments.dropFirst().first ?? "com.follow.clash"

guard let defaults = UserDefaults(suiteName: bundleID),
      let domain = defaults.persistentDomain(forName: bundleID),
      let configString = domain["flutter.config"] as? String,
      let configData = configString.data(using: .utf8),
      let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
else {
    FileHandle.standardError.write(Data("unable to read FlClash preference state\n".utf8))
    exit(1)
}

let appSettings = dictionaryValue(config, key: "appSettingProps")
let networkSettings = dictionaryValue(config, key: "networkProps")
let patchConfig = dictionaryValue(config, key: "patchClashConfig")
let tun = dictionaryValue(patchConfig, key: "tun")
let dashboardWidgets = appSettings["dashboardWidgets"] as? [String] ?? []

print("auto_run=\(boolValue(appSettings, key: "autoRun", default: false))")
print("silent_launch=\(boolValue(appSettings, key: "silentLaunch", default: false))")
print("show_tray_title=\(boolValue(appSettings, key: "showTrayTitle", default: true))")
print("override_dns=\(boolValue(config, key: "overrideDns", default: false))")
print("dashboard_widget_count=\(dashboardWidgets.count)")
print("dashboard_has_network_speed=\(dashboardWidgets.contains("networkSpeed"))")
print("dashboard_has_traffic_usage=\(dashboardWidgets.contains("trafficUsage"))")
print("dashboard_has_network_detection=\(dashboardWidgets.contains("networkDetection"))")
print("dashboard_has_intranet_ip=\(dashboardWidgets.contains("intranetIp"))")
print("dashboard_has_memory_info=\(dashboardWidgets.contains("memoryInfo"))")
print("system_proxy_preference=\(boolValue(networkSettings, key: "systemProxy", default: true))")
print("tun_preference=\(boolValue(tun, key: "enable", default: false))")
print("ipv6_preference=\(boolValue(patchConfig, key: "ipv6", default: false))")
print("tun_stack=\(tun["stack"] as? String ?? "mixed")")
print(
    "external_controller_preference=\((patchConfig["external-controller"] as? String ?? "").isEmpty == false)"
)

let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
let processIDs = Set(runningApps.map(\.processIdentifier))
let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let visibleWindows = windowInfo.filter { window in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
          processIDs.contains(ownerPID),
          let layer = window[kCGWindowLayer as String] as? Int
    else {
        return false
    }
    return layer == 0
}
let visibleWindowAreas = visibleWindows.compactMap { window -> Double? in
    guard let rawBounds = window[kCGWindowBounds as String],
          let bounds = CGRect(dictionaryRepresentation: rawBounds as! CFDictionary)
    else {
        return nil
    }
    return Double(bounds.width * bounds.height)
}

print("app_running=\(!runningApps.isEmpty)")
print("visible_window_count=\(visibleWindows.count)")
print("visible_window_max_area=\(Int(visibleWindowAreas.max() ?? 0))")
