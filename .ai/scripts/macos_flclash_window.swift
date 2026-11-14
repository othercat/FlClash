import AppKit
import Foundation

let command = CommandLine.arguments.dropFirst().first ?? "status"
let bundleID = "com.follow.clash"
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)

guard applications.count == 1, let application = applications.first else {
    FileHandle.standardError.write(
        Data("expected exactly one running FlClash application\n".utf8)
    )
    exit(1)
}

switch command {
case "hide":
    application.hide()
    Thread.sleep(forTimeInterval: 0.5)
    guard application.isHidden else {
        FileHandle.standardError.write(Data("unable to hide FlClash\n".utf8))
        exit(1)
    }
    print("window_action=hidden")
case "show":
    application.unhide()
    application.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.5)
    guard !application.isHidden else {
        FileHandle.standardError.write(Data("unable to unhide FlClash\n".utf8))
        exit(1)
    }
    print("window_action=shown")
case "status":
    print("application_hidden=\(application.isHidden)")
case "help", "--help", "-h":
    print("usage: macos_flclash_window.swift hide|show|status")
default:
    FileHandle.standardError.write(Data("unknown command\n".utf8))
    exit(64)
}
