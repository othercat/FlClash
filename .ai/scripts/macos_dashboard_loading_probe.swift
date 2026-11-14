import AppKit
import ApplicationServices
import Foundation

struct TextRecord {
    let strings: [String]
    let position: CGPoint?
    let size: CGSize?
}

private func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    if let value = attribute(element, name) as? String {
        return value
    }
    if let value = attribute(element, name) as? NSAttributedString {
        return value.string
    }
    return nil
}

private func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let rawValue = attribute(element, name),
          CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
        return nil
    }
    var value = CGPoint.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgPoint, &value) else {
        return nil
    }
    return value
}

private func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let rawValue = attribute(element, name),
          CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
        return nil
    }
    var value = CGSize.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgSize, &value) else {
        return nil
    }
    return value
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
    var children: [AXUIElement] = []
    var seen = Set<CFHashCode>()
    for name in names {
        for child in attribute(element, name) as? [AXUIElement] ?? [] {
            if seen.insert(CFHash(child)).inserted {
                children.append(child)
            }
        }
    }
    return children
}

private func strings(_ element: AXUIElement) -> [String] {
    [
        stringAttribute(element, kAXTitleAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXHelpAttribute as CFString),
        stringAttribute(element, kAXValueAttribute as CFString),
    ].compactMap { $0 }.filter { !$0.isEmpty }
}

private func containsOneOf(_ record: TextRecord, _ values: [String]) -> Bool {
    record.strings.contains { candidate in
        values.contains { value in
            candidate.range(
                of: value,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}

private func matches(_ pattern: String, in value: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return false
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.firstMatch(in: value, range: range) != nil
}

private func containsIPAddress(_ record: TextRecord) -> Bool {
    record.strings.contains { value in
        matches(#"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])"#, in: value)
            || matches(#"(?i)(?:[0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}"#, in: value)
    }
}

private func center(_ record: TextRecord) -> CGPoint? {
    guard let position = record.position, let size = record.size else {
        return nil
    }
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
}

private func belongsToCard(_ candidate: TextRecord, title: TextRecord) -> Bool {
    guard let candidateCenter = center(candidate), let titleCenter = center(title) else {
        return false
    }
    let deltaX = abs(candidateCenter.x - titleCenter.x)
    let deltaY = candidateCenter.y - titleCenter.y
    return deltaX <= 210 && deltaY >= -20 && deltaY <= 180
}

private func classifiedState(title: TextRecord?, records: [TextRecord]) -> String {
    guard let title else {
        return "title_unavailable"
    }
    let nearby = records.filter { belongsToCard($0, title: title) }
    if nearby.contains(where: { containsOneOf($0, ["Timeout"]) }) {
        return "timeout"
    }
    if nearby.contains(where: { containsOneOf($0, ["No network", "无网络"]) }) {
        return "no_network"
    }
    if nearby.contains(where: containsIPAddress) {
        return "ip_redacted"
    }
    return "loading_candidate"
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("accessibility_permission=false\n".utf8))
    exit(1)
}

let running = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.follow.clash"
)
guard running.count == 1, let processID = running.first?.processIdentifier else {
    FileHandle.standardError.write(Data("expected exactly one FlClash process\n".utf8))
    exit(1)
}

let application = AXUIElementCreateApplication(processID)
guard let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement],
      !windows.isEmpty
else {
    FileHandle.standardError.write(Data("flclash_window_unavailable\n".utf8))
    exit(1)
}

var queue = windows
var cursor = 0
var visited = Set<CFHashCode>()
var records: [TextRecord] = []
while cursor < queue.count && visited.count < 5_000 {
    let element = queue[cursor]
    cursor += 1
    guard visited.insert(CFHash(element)).inserted else {
        continue
    }
    let values = strings(element)
    if !values.isEmpty {
        records.append(TextRecord(
            strings: values,
            position: pointAttribute(element, kAXPositionAttribute as CFString),
            size: sizeAttribute(element, kAXSizeAttribute as CFString)
        ))
    }
    queue.append(contentsOf: structuralChildren(element))
}

let networkTitles = records.filter {
    containsOneOf($0, ["Network detection", "网络检测"])
}
let intranetTitles = records.filter {
    containsOneOf($0, ["Intranet IP", "内网 IP"])
}

print("scan_complete=true")
print("nodes_scanned=\(visited.count)")
print("network_detection_title_count=\(networkTitles.count)")
print("network_detection_state=\(classifiedState(title: networkTitles.first, records: records))")
print("intranet_ip_title_count=\(intranetTitles.count)")
print("intranet_ip_state=\(classifiedState(title: intranetTitles.first, records: records))")
