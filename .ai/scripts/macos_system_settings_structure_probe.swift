import AppKit
import ApplicationServices
import Foundation

private func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    attribute(element, name) as? String
}

private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
    attribute(element, name) as? Bool
}

private func structuralChildren(_ element: AXUIElement) -> [AXUIElement] {
    let names = [
        kAXChildrenAttribute,
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXRowsAttribute,
        kAXColumnsAttribute,
        kAXTabsAttribute,
    ].map { $0 as CFString }
    var result: [AXUIElement] = []
    var seen = Set<CFHashCode>()
    for name in names {
        let children = attribute(element, name) as? [AXUIElement] ?? []
        for child in children where seen.insert(CFHash(child)).inserted {
            result.append(child)
        }
    }
    return result
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("accessibility_permission=false\n".utf8))
    exit(1)
}

let running = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.systempreferences"
)
guard running.count == 1, let processID = running.first?.processIdentifier else {
    FileHandle.standardError.write(Data("expected exactly one System Settings process\n".utf8))
    exit(1)
}

let application = AXUIElementCreateApplication(processID)
let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
var queue = windows.map { ($0, 0) }
var cursor = 0
var visited = Set<CFHashCode>()
var roleCounts: [String: Int] = [:]
var busyTrueCount = 0
let maximumNodes = 10_000
let maximumDepth = 50

while cursor < queue.count && visited.count < maximumNodes {
    let (element, depth) = queue[cursor]
    cursor += 1
    let hash = CFHash(element)
    guard visited.insert(hash).inserted else {
        continue
    }

    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
    roleCounts[role, default: 0] += 1
    if boolAttribute(element, "AXBusy" as CFString) == true {
        busyTrueCount += 1
    }
    if depth < maximumDepth {
        queue.append(contentsOf: structuralChildren(element).map { ($0, depth + 1) })
    }
}

print("system_settings_running=true")
print("window_count=\(windows.count)")
print("nodes_scanned=\(visited.count)")
print("busy_true_count=\(busyTrueCount)")
for role in [
    kAXProgressIndicatorRole as String,
    kAXGroupRole as String,
    kAXButtonRole as String,
    kAXStaticTextRole as String,
    kAXImageRole as String,
    kAXScrollAreaRole as String,
] {
    print("role_count[\(role)]=\(roleCounts[role] ?? 0)")
}
