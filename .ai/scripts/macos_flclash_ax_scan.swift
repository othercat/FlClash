import AppKit
import ApplicationServices
import Foundation

private let allowedLabels = [
    "Dashboard",
    "仪表盘",
    "Tools",
    "工具",
    "Settings",
    "设置",
    "Basic configuration",
    "基本配置",
    "General",
    "常规",
    "External controller",
    "外部控制器",
    "System proxy",
    "系统代理",
    "TUN",
    "虚拟网卡",
    "Core status",
    "核心状态",
    "Confirm",
    "确定",
]

private var allowedPressLabels = [
    "Dashboard",
    "仪表盘",
    "Tools",
    "工具",
    "Basic configuration",
    "基本配置",
    "External controller",
    "外部控制器",
]

if ProcessInfo.processInfo.environment["FLCLASH_PHASE1_ALLOW_PROXY_AX"] == "1" {
    allowedPressLabels.append(contentsOf: ["System proxy", "系统代理"])
}

if ProcessInfo.processInfo.environment["FLCLASH_PHASE1_ALLOW_TUN_AX"] == "1" {
    allowedPressLabels.append(contentsOf: ["TUN", "虚拟网卡"])
}

if ProcessInfo.processInfo.environment["FLCLASH_PHASE1_ALLOW_CORE_RESTART_AX"] == "1" {
    allowedPressLabels.append(contentsOf: ["Core status", "核心状态", "Confirm", "确定"])
}

private func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    let value = attribute(element, name)
    if let string = value as? String {
        return string
    }
    if let attributedString = value as? NSAttributedString {
        return attributedString.string
    }
    return nil
}

private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
    attribute(element, name) as? Bool
}

private func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let value = attribute(element, name) else {
        return nil
    }
    var point = CGPoint.zero
    guard AXValueGetType(value as! AXValue) == .cgPoint,
          AXValueGetValue(value as! AXValue, .cgPoint, &point)
    else {
        return nil
    }
    return point
}

private func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let value = attribute(element, name) else {
        return nil
    }
    var size = CGSize.zero
    guard AXValueGetType(value as! AXValue) == .cgSize,
          AXValueGetValue(value as! AXValue, .cgSize, &size)
    else {
        return nil
    }
    return size
}

private func structuralChildren(_ element: AXUIElement) -> [AXUIElement] {
    let structuralAttributes = [
        kAXChildrenAttribute,
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXRowsAttribute,
        kAXColumnsAttribute,
        kAXTabsAttribute,
    ].map { $0 as CFString }
    var result: [AXUIElement] = []
    var seen = Set<CFHashCode>()
    for name in structuralAttributes {
        let elements = attribute(element, name) as? [AXUIElement] ?? []
        for child in elements where seen.insert(CFHash(child)).inserted {
            result.append(child)
        }
    }
    return result
}

private func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else {
        return []
    }
    return names as? [String] ?? []
}

private func matchedLabel(_ element: AXUIElement) -> String? {
    let strings = [
        stringAttribute(element, kAXTitleAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXHelpAttribute as CFString),
        stringAttribute(element, kAXRoleDescriptionAttribute as CFString),
        stringAttribute(element, kAXValueAttribute as CFString),
    ].compactMap { $0 }

    return allowedLabels.first { allowed in
        strings.contains { candidate in
            candidate.range(
                of: allowed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
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
var applicationAttributeNames: CFArray?
let attributeNamesStatus = AXUIElementCopyAttributeNames(
    application,
    &applicationAttributeNames
)
let applicationAttributes = attributeNamesStatus == .success
    ? (applicationAttributeNames as? [String] ?? [])
    : []

let requestedPressLabel: String?
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "press-label"
{
    let label = CommandLine.arguments[2]
    guard allowedPressLabels.contains(label) else {
        FileHandle.standardError.write(Data("press-label is not allowed\n".utf8))
        exit(64)
    }
    requestedPressLabel = label
} else {
    requestedPressLabel = nil
}

let shouldScanButtons = CommandLine.arguments.count == 2 &&
    CommandLine.arguments[1] == "scan-buttons"
let shouldPressCoreStatusButton = CommandLine.arguments.count == 2 &&
    CommandLine.arguments[1] == "press-core-status-button"
let shouldScanControls = CommandLine.arguments.count == 2 &&
    CommandLine.arguments[1] == "scan-controls"
let shouldToggleTunSheetCheckbox = CommandLine.arguments.count == 2 &&
    CommandLine.arguments[1] == "toggle-tun-sheet-checkbox"

if shouldToggleTunSheetCheckbox &&
   ProcessInfo.processInfo.environment["FLCLASH_PHASE1_ALLOW_TUN_AX"] != "1"
{
    FileHandle.standardError.write(Data("toggle-tun-sheet-checkbox is not allowed\n".utf8))
    exit(64)
}

if shouldPressCoreStatusButton &&
   ProcessInfo.processInfo.environment["FLCLASH_PHASE1_ALLOW_CORE_RESTART_AX"] != "1"
{
    FileHandle.standardError.write(Data("press-core-status-button is not allowed\n".utf8))
    exit(64)
}

if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "set-enhanced"
{
    let requestedValue: Bool
    switch CommandLine.arguments[2] {
    case "true":
        requestedValue = true
    case "false":
        requestedValue = false
    default:
        FileHandle.standardError.write(Data("set-enhanced requires true or false\n".utf8))
        exit(64)
    }
    guard applicationAttributes.contains("AXEnhancedUserInterface") else {
        FileHandle.standardError.write(Data("enhanced user interface is unsupported\n".utf8))
        exit(1)
    }
    let setStatus = AXUIElementSetAttributeValue(
        application,
        "AXEnhancedUserInterface" as CFString,
        requestedValue ? kCFBooleanTrue : kCFBooleanFalse
    )
    var confirmed = false
    for _ in 0..<10 {
        Thread.sleep(forTimeInterval: 0.5)
        if boolAttribute(application, "AXEnhancedUserInterface" as CFString) == requestedValue {
            confirmed = true
            break
        }
    }
    guard confirmed else {
        let message = "enhanced user interface did not reach requested state (status=\(setStatus.rawValue))\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
    print("enhanced_user_interface=\(requestedValue)")
    exit(0)
}

guard let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement],
      !windows.isEmpty
else {
    FileHandle.standardError.write(Data("flclash_window_unavailable\n".utf8))
    exit(1)
}

if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "close-window"
{
    guard ProcessInfo.processInfo.environment["FLCLASH_PHASE1_ALLOW_WINDOW_CLOSE_AX"] == "1" else {
        FileHandle.standardError.write(Data("close-window is not allowed\n".utf8))
        exit(64)
    }
    guard windows.count == 1,
          let closeButtonValue = attribute(
              windows[0],
              kAXCloseButtonAttribute as CFString
          ),
          CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID()
    else {
        FileHandle.standardError.write(Data("expected one closable FlClash window\n".utf8))
        exit(1)
    }
    let closeButton = unsafeBitCast(closeButtonValue, to: AXUIElement.self)
    guard actionNames(closeButton).contains(kAXPressAction as String),
          AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    else {
        FileHandle.standardError.write(Data("expected one closable FlClash window\n".utf8))
        exit(1)
    }
    print("ordinary_window_closed=true")
    exit(0)
}

var queue = windows.map { ($0, 0) }
var cursor = 0
var visited = Set<CFHashCode>()
var matches = 0
var foundLabels = Set<String>()
var pressCandidates: [(element: AXUIElement, role: String)] = []
var roleCounts: [String: Int] = [:]
var buttons: [(element: AXUIElement, depth: Int, label: String?, enabled: Bool?, position: CGPoint?, size: CGSize?, actions: [String])] = []
var checkboxes: [(element: AXUIElement, depth: Int, enabled: Bool?, position: CGPoint?, size: CGSize?, value: Bool?, actions: [String])] = []
let maximumNodes = 5_000
let maximumDepth = 40

while cursor < queue.count && visited.count < maximumNodes {
    let (element, depth) = queue[cursor]
    cursor += 1

    let hash = CFHash(element)
    guard visited.insert(hash).inserted else {
        continue
    }

    let currentRole = stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
    roleCounts[currentRole, default: 0] += 1

    if (shouldScanButtons || shouldPressCoreStatusButton) &&
       currentRole == (kAXButtonRole as String)
    {
        buttons.append((
            element,
            depth,
            matchedLabel(element),
            boolAttribute(element, kAXEnabledAttribute as CFString),
            pointAttribute(element, kAXPositionAttribute as CFString),
            sizeAttribute(element, kAXSizeAttribute as CFString),
            actionNames(element)
        ))
    }
    if (shouldScanControls || shouldToggleTunSheetCheckbox) &&
       currentRole == (kAXCheckBoxRole as String)
    {
        checkboxes.append((
            element,
            depth,
            boolAttribute(element, kAXEnabledAttribute as CFString),
            pointAttribute(element, kAXPositionAttribute as CFString),
            sizeAttribute(element, kAXSizeAttribute as CFString),
            boolAttribute(element, kAXValueAttribute as CFString),
            actionNames(element)
        ))
    }

    if let label = matchedLabel(element) {
        foundLabels.insert(label)
        let enabled = boolAttribute(element, kAXEnabledAttribute as CFString)
        let actions = actionNames(element).filter {
            [kAXPressAction, kAXShowMenuAction, kAXIncrementAction, kAXDecrementAction]
                .map { $0 as String }
                .contains($0)
        }
        var fields = [
            "match=\(label)",
            "role=\(currentRole)",
            "actions=\(actions.joined(separator: ","))",
        ]
        if let enabled {
            fields.append("enabled=\(enabled)")
        }
        if let value = attribute(element, kAXValueAttribute as CFString) {
            if let boolValue = value as? Bool {
                fields.append("value_bool=\(boolValue)")
            } else if let numberValue = value as? NSNumber {
                fields.append("value_number=\(numberValue)")
            }
        }
        print(fields.joined(separator: " "))
        matches += 1
        if label == requestedPressLabel,
           actionNames(element).contains(kAXPressAction as String)
        {
            pressCandidates.append((element, currentRole))
        }
    }

    if depth < maximumDepth {
        queue.append(contentsOf: structuralChildren(element).map { ($0, depth + 1) })
    }
}

if let requestedPressLabel {
    let concreteCandidates = pressCandidates.filter {
        $0.role != (kAXGroupRole as String)
    }
    let candidates = concreteCandidates.isEmpty ? pressCandidates : concreteCandidates
    guard candidates.count == 1 else {
        FileHandle.standardError.write(
            Data("expected exactly one allowed press target\n".utf8)
        )
        exit(1)
    }
    let target = candidates[0].element
    guard actionNames(target).contains(kAXPressAction as String),
          AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    else {
        FileHandle.standardError.write(Data("allowed press action failed\n".utf8))
        exit(1)
    }
    print("pressed_label=\(requestedPressLabel)")
}

if shouldPressCoreStatusButton {
    let dashboardReady =
        (!foundLabels.isDisjoint(with: ["Dashboard", "仪表盘"])) &&
        (!foundLabels.isDisjoint(with: ["Tools", "工具"])) &&
        (!foundLabels.isDisjoint(with: ["System proxy", "系统代理"])) &&
        (!foundLabels.isDisjoint(with: ["TUN", "虚拟网卡"]))
    guard dashboardReady,
          windows.count == 1,
          let windowPosition = pointAttribute(windows[0], kAXPositionAttribute as CFString),
          let windowSize = sizeAttribute(windows[0], kAXSizeAttribute as CFString)
    else {
        FileHandle.standardError.write(Data("dashboard guard is not ready\n".utf8))
        exit(1)
    }
    let candidates = buttons.filter { button in
        guard button.enabled == true,
              button.actions.contains(kAXPressAction as String),
              let position = button.position,
              let size = button.size
        else {
            return false
        }
        return size.width >= 30 && size.width <= 34 &&
            size.height >= 30 && size.height <= 34 &&
            position.x >= windowPosition.x + windowSize.width - 100 &&
            position.x <= windowPosition.x + windowSize.width - 48 &&
            position.y <= windowPosition.y + 80
    }
    guard candidates.count == 1,
          AXUIElementPerformAction(
              candidates[0].element,
              kAXPressAction as CFString
          ) == .success
    else {
        FileHandle.standardError.write(
            Data("expected one guarded core-status button\n".utf8)
        )
        exit(1)
    }
    print("core_status_button_pressed=true")
}

if shouldScanButtons {
    for (index, button) in buttons.enumerated() {
        let label = button.label ?? "unlabeled"
        let actions = button.actions.joined(separator: ",")
        var fields = [
            "button_index=\(index)",
            "depth=\(button.depth)",
            "label=\(label)",
            "actions=\(actions)",
        ]
        if let enabled = button.enabled {
            fields.append("enabled=\(enabled)")
        }
        if let position = button.position {
            fields.append("x=\(Int(position.x.rounded()))")
            fields.append("y=\(Int(position.y.rounded()))")
        }
        if let size = button.size {
            fields.append("width=\(Int(size.width.rounded()))")
            fields.append("height=\(Int(size.height.rounded()))")
        }
        print(fields.joined(separator: " "))
    }
}

if shouldScanControls {
    for (index, checkbox) in checkboxes.enumerated() {
        var fields = [
            "checkbox_index=\(index)",
            "depth=\(checkbox.depth)",
            "actions=\(checkbox.actions.joined(separator: ","))",
        ]
        if let enabled = checkbox.enabled {
            fields.append("enabled=\(enabled)")
        }
        if let value = checkbox.value {
            fields.append("value_bool=\(value)")
        }
        if let position = checkbox.position {
            fields.append("x=\(Int(position.x.rounded()))")
            fields.append("y=\(Int(position.y.rounded()))")
        }
        if let size = checkbox.size {
            fields.append("width=\(Int(size.width.rounded()))")
            fields.append("height=\(Int(size.height.rounded()))")
        }
        print(fields.joined(separator: " "))
    }
}

if shouldToggleTunSheetCheckbox {
    let eligible = checkboxes.filter {
        $0.enabled == true &&
            $0.position != nil &&
            $0.actions.contains(kAXPressAction as String)
    }.sorted {
        $0.position!.y < $1.position!.y
    }
    guard eligible.count == 2,
          matches >= 5,
          eligible[1].position!.y - eligible[0].position!.y >= 30
    else {
        FileHandle.standardError.write(
            Data("expected two separated TUN sheet checkboxes\n".utf8)
        )
        exit(1)
    }
    let target = eligible[0]
    guard AXUIElementPerformAction(
        target.element,
        kAXPressAction as CFString
    ) == .success else {
        FileHandle.standardError.write(Data("TUN sheet checkbox press failed\n".utf8))
        exit(1)
    }
    print("tun_sheet_checkbox_pressed=true")
    if let value = target.value {
        print("tun_sheet_checkbox_value_before=\(value)")
    }
}

print("scan_complete=true")
print("supports_manual_accessibility=\(applicationAttributes.contains("AXManualAccessibility"))")
print("supports_enhanced_user_interface=\(applicationAttributes.contains("AXEnhancedUserInterface"))")
print(
    "enhanced_user_interface=\(boolAttribute(application, "AXEnhancedUserInterface" as CFString) ?? false)"
)
print("nodes_scanned=\(visited.count)")
print("matches=\(matches)")
for role in roleCounts.keys.sorted() {
    print("role_count[\(role)]=\(roleCounts[role] ?? 0)")
}
