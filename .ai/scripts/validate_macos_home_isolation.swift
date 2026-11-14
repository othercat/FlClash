import Foundation

private func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
}

private func isInside(_ path: String, root: String) -> Bool {
    let normalizedPath = normalized(path)
    let normalizedRoot = normalized(root)
    return normalizedPath == normalizedRoot
        || normalizedPath.hasPrefix(normalizedRoot + "/")
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: validate_macos_home_isolation.swift EXPECTED_ROOT SUITE_ID\n".utf8)
    )
    exit(64)
}

let expectedRoot = CommandLine.arguments[1]
let suiteID = CommandLine.arguments[2]
let fileManager = FileManager.default
let home = NSHomeDirectory()
let applicationSupport = fileManager.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
).first?.path ?? ""
let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""

let homeIsolated = isInside(home, root: expectedRoot)
let applicationSupportIsolated = isInside(applicationSupport, root: expectedRoot)
let cachesIsolated = isInside(caches, root: expectedRoot)

print("home_isolated=\(homeIsolated)")
print("application_support_isolated=\(applicationSupportIsolated)")
print("caches_isolated=\(cachesIsolated)")

guard homeIsolated, applicationSupportIsolated, cachesIsolated else {
    FileHandle.standardError.write(
        Data("refusing preference write because directory isolation failed\n".utf8)
    )
    exit(1)
}

guard let defaults = UserDefaults(suiteName: suiteID) else {
    FileHandle.standardError.write(Data("unable to create isolated defaults suite\n".utf8))
    exit(1)
}

defaults.set("phase1-isolation-marker", forKey: "marker")
let synchronized = defaults.synchronize()
let markerRoundTrip = defaults.string(forKey: "marker") == "phase1-isolation-marker"

print("preferences_synchronized=\(synchronized)")
print("preferences_round_trip=\(markerRoundTrip)")

guard synchronized, markerRoundTrip else {
    exit(1)
}
