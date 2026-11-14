import AppKit
import ApplicationServices
import Foundation

private let speedLabels = ["网速统计", "Speed statistics"]

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

private func structuralChildren(_ element: AXUIElement) -> [AXUIElement] {
    let names = [
        kAXChildrenAttribute,
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
    ].map { $0 as CFString }
    var result: [AXUIElement] = []
    var seen = Set<CFHashCode>()
    for name in names {
        for child in attribute(element, name) as? [AXUIElement] ?? []
        where seen.insert(CFHash(child)).inserted {
            result.append(child)
        }
    }
    return result
}

private func frame(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = attribute(element, kAXPositionAttribute as CFString),
          let rawSize = attribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          CFGetTypeID(rawSize) == AXValueGetTypeID()
    else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
          AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
    else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

private func realClick(_ point: CGPoint, button: CGMouseButton = .left) -> Bool {
    let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(
              mouseEventSource: source,
              mouseType: downType,
              mouseCursorPosition: point,
              mouseButton: button
          ),
          let up = CGEvent(
              mouseEventSource: source,
              mouseType: upType,
              mouseCursorPosition: point,
              mouseButton: button
          )
    else {
        return false
    }
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    up.post(tap: .cghidEventTap)
    return true
}

private func pressEscape() {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(
              keyboardEventSource: source,
              virtualKey: 53,
              keyDown: true
          ),
          let up = CGEvent(
              keyboardEventSource: source,
              virtualKey: 53,
              keyDown: false
          )
    else {
        return
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func matchesSpeedLabel(_ element: AXUIElement) -> Bool {
    let values = [
        stringAttribute(element, kAXTitleAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXValueAttribute as CFString),
    ].compactMap { $0 }
    return speedLabels.contains { label in
        values.contains { $0 == label }
    }
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
guard let rawExtras = attribute(application, "AXExtrasMenuBar" as CFString),
      CFGetTypeID(rawExtras) == AXUIElementGetTypeID()
else {
    FileHandle.standardError.write(Data("flclash_extras_menu_bar_unavailable\n".utf8))
    exit(1)
}
let extras = rawExtras as! AXUIElement
let statusItems = structuralChildren(extras).filter {
    stringAttribute($0, kAXRoleAttribute as CFString) == (kAXMenuBarItemRole as String)
        && frame($0) != nil
}
print("status_item_count=\(statusItems.count)")

let command = CommandLine.arguments.dropFirst().first ?? "locate"
if command == "locate" {
    exit(statusItems.count == 1 ? 0 : 1)
}
guard command == "click-open" || command == "scan-menu" ||
      command == "click-speed-statistics" else {
    FileHandle.standardError.write(
        Data(
            (
                "usage: macos_flclash_tray_real_click.swift " +
                    "locate|click-open|scan-menu|click-speed-statistics\n"
            ).utf8
        )
    )
    exit(64)
}
guard statusItems.count == 1, let statusFrame = frame(statusItems[0]) else {
    FileHandle.standardError.write(Data("expected exactly one FlClash status item\n".utf8))
    exit(1)
}

let originalPointer = CGEvent(source: nil)?.location
if command == "click-open" {
    guard realClick(CGPoint(x: statusFrame.midX, y: statusFrame.midY)) else {
        FileHandle.standardError.write(Data("real status item click failed\n".utf8))
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.8)
    if let originalPointer {
        _ = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: originalPointer,
            mouseButton: .left
        ).map { $0.post(tap: .cghidEventTap) }
    }
    print("real_open_click_complete=true")
    exit(0)
}
guard realClick(
    CGPoint(x: statusFrame.midX, y: statusFrame.midY),
    button: .right
) else {
    FileHandle.standardError.write(Data("real status item click failed\n".utf8))
    exit(1)
}
Thread.sleep(forTimeInterval: 1.2)

var queue = [application, extras, statusItems[0]]
var cursor = 0
var visited = Set<CFHashCode>()
var speedItems: [AXUIElement] = []
while cursor < queue.count && visited.count < 2_000 {
    let element = queue[cursor]
    cursor += 1
    guard visited.insert(CFHash(element)).inserted else {
        continue
    }
    if stringAttribute(element, kAXRoleAttribute as CFString) == (kAXMenuItemRole as String),
       matchesSpeedLabel(element),
       frame(element) != nil
    {
        speedItems.append(element)
    }
    queue.append(contentsOf: structuralChildren(element))
}
print("speed_statistics_item_count=\(speedItems.count)")

if command == "scan-menu" {
    pressEscape()
    if let originalPointer {
        _ = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: originalPointer,
            mouseButton: .left
        ).map { $0.post(tap: .cghidEventTap) }
    }
    exit(speedItems.count == 1 ? 0 : 1)
}

guard speedItems.count == 1, let itemFrame = frame(speedItems[0]) else {
    pressEscape()
    FileHandle.standardError.write(Data("expected exactly one speed statistics menu item\n".utf8))
    exit(1)
}
guard realClick(CGPoint(x: itemFrame.midX, y: itemFrame.midY)) else {
    pressEscape()
    FileHandle.standardError.write(Data("real speed statistics click failed\n".utf8))
    exit(1)
}
Thread.sleep(forTimeInterval: 0.8)
if let originalPointer {
    _ = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: originalPointer,
        mouseButton: .left
    ).map { $0.post(tap: .cghidEventTap) }
}
print("real_click_complete=true")
