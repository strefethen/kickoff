import AppKit
import Darwin
import Foundation

/// Picks the Chrome the user browses in, ignoring instances driven by automation tools.
enum UserChrome {
    static let bundleIdentifier = "com.google.Chrome"

    struct Instance: Equatable {
        let pid: pid_t
        let launchDate: Date?
        let arguments: [String]?
    }

    private static let automationFlags = [
        "--enable-automation",
        "--remote-debugging-pipe",
        "--remote-debugging-port",
        "--headless",
        "--test-type",
    ]

    static func isAutomated(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            automationFlags.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }
    }

    static func usesCustomProfile(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--user-data-dir" || $0.hasPrefix("--user-data-dir=") }
    }

    static func choose(_ instances: [Instance]) -> pid_t? {
        instances
            .filter { !isAutomated($0.arguments ?? []) }
            .min { lhs, rhs in
                let lhsCustom = usesCustomProfile(lhs.arguments ?? [])
                let rhsCustom = usesCustomProfile(rhs.arguments ?? [])
                if lhsCustom != rhsCustom { return !lhsCustom }
                return (lhs.launchDate ?? .distantFuture) < (rhs.launchDate ?? .distantFuture)
            }?
            .pid
    }

    static func runningInstances() -> [Instance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map {
            Instance(pid: $0.processIdentifier, launchDate: $0.launchDate, arguments: arguments(of: $0.processIdentifier))
        }
    }

    static func runningPID() -> pid_t? {
        choose(runningInstances())
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while index < size, arguments.count < argc {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
