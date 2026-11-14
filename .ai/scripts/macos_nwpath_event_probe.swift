import Foundation
import Network

struct Transition {
    let second: Int
    let signature: String
}

private func pluginConnectivitySignature(_ path: NWPath) -> String {
    var types: [String] = []
    if path.status == .satisfied {
        if path.usesInterfaceType(.wifi) {
            types.append("wifi")
        }
        if path.usesInterfaceType(.cellular) {
            types.append("mobile")
        }
        if path.usesInterfaceType(.wiredEthernet) {
            types.append("ethernet")
        }
        if path.usesInterfaceType(.other) {
            types.append("other")
        }
    }
    return types.isEmpty ? "none" : types.joined(separator: ",")
}

let durationArgument = CommandLine.arguments.dropFirst().first ?? "30"
guard let duration = Int(durationArgument), (1...300).contains(duration) else {
    FileHandle.standardError.write(
        Data("duration must be an integer between 1 and 300 seconds\n".utf8)
    )
    exit(64)
}

let monitor = NWPathMonitor()
let queue = DispatchQueue(label: "flclash.phase1.nwpath-probe")
let lock = NSLock()
let startedAt = DispatchTime.now().uptimeNanoseconds
var updateCount = 0
var duplicateCount = 0
var lastSignature: String?
var transitions: [Transition] = []

monitor.pathUpdateHandler = { path in
    let signature = pluginConnectivitySignature(path)
    let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
    let elapsedSecond = Int(elapsedNanoseconds / 1_000_000_000)

    lock.lock()
    defer { lock.unlock() }
    updateCount += 1
    if signature == lastSignature {
        duplicateCount += 1
        return
    }
    lastSignature = signature
    transitions.append(Transition(second: elapsedSecond, signature: signature))
}

monitor.start(queue: queue)
RunLoop.current.run(until: Date().addingTimeInterval(TimeInterval(duration)))
monitor.cancel()
queue.sync {}

lock.lock()
let finalUpdateCount = updateCount
let finalDuplicateCount = duplicateCount
let finalTransitions = transitions
lock.unlock()

print("capture_seconds=\(duration)")
print("native_update_count=\(finalUpdateCount)")
print("dart_distinct_transition_count=\(finalTransitions.count)")
print("native_duplicate_signature_count=\(finalDuplicateCount)")
for (index, transition) in finalTransitions.enumerated() {
    let prefix = "transition_\(index + 1)"
    print("\(prefix)_second=\(transition.second)")
    print("\(prefix)_types=\(transition.signature)")
}
