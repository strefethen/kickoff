import Foundation
import CoreGraphics

/// A value snapshot; the UUID is the preference key, while displayID is valid only now.
struct Monitor: Equatable {
    let identifier: String
    let displayID: CGDirectDisplayID
    let name: String
    let isPrimary: Bool
    let bounds: CGRect
    let visibleBounds: CGRect
}

struct MonitorPreference: Equatable {
    let identifier: String
    let name: String
}

struct MonitorSelectionSnapshot {
    let monitors: [Monitor]
    let preferred: MonitorPreference?

    var target: Monitor? {
        if let preferred, let match = monitors.first(where: { $0.identifier == preferred.identifier }) {
            return match
        }
        let fallbackOrder = monitors.sorted {
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return $0.identifier < $1.identifier
        }
        return fallbackOrder.first(where: { !$0.isPrimary }) ?? fallbackOrder.first
    }

    var unavailablePreference: MonitorPreference? {
        guard let preferred, !monitors.contains(where: { $0.identifier == preferred.identifier }) else { return nil }
        return preferred
    }

    func title(for monitor: Monitor) -> String {
        let sameName = monitors.filter { $0.name == monitor.name }
        guard sameName.count > 1, let index = sameName.firstIndex(of: monitor) else { return monitor.name }
        return "\(monitor.name) (\(index + 1))"
    }
}

/// Owns the saved choice and the authorized fallback policy, independently of menu and Chrome.
final class MonitorSelection {
    private static let preferenceKey = "preferredMonitor"
    private let defaults: UserDefaults
    private let discover: () -> [Monitor]

    init(
        defaults: UserDefaults? = nil,
        discover: @escaping () -> [Monitor] = SystemMonitorProvider.monitors
    ) {
        self.defaults = defaults ?? AppPreferences.applicationDefaults()
        self.discover = discover
    }

    func snapshot() -> MonitorSelectionSnapshot {
        let saved = defaults.dictionary(forKey: Self.preferenceKey)
        let preference: MonitorPreference?
        if let identifier = saved?["identifier"] as? String, let name = saved?["name"] as? String {
            preference = MonitorPreference(identifier: identifier, name: name)
        } else {
            preference = nil
        }
        // Primary first for presentation, then secondary displays from left to right.
        let monitors = discover().sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return $0.identifier < $1.identifier
        }
        return MonitorSelectionSnapshot(monitors: monitors, preferred: preference)
    }

    @discardableResult
    func select(identifier: String) -> Bool {
        let current = snapshot()
        guard let monitor = current.monitors.first(where: { $0.identifier == identifier }) else { return false }
        defaults.set(["identifier": monitor.identifier, "name": current.title(for: monitor)], forKey: Self.preferenceKey)
        return true
    }

    func pinTarget() throws -> MonitorTarget {
        guard let target = snapshot().target else { throw MonitorSelectionFailure("No available monitor for Chrome setup.") }
        return MonitorTarget(monitor: target, discover: discover)
    }
}

/// A setup run keeps one target. Hotplug may change the next run, never this one.
struct MonitorTarget {
    let monitor: Monitor
    private let discover: () -> [Monitor]

    init(monitor: Monitor, discover: @escaping () -> [Monitor]) {
        self.monitor = monitor
        self.discover = discover
    }

    func validate() throws -> Monitor {
        let matches = discover().filter { $0.identifier == monitor.identifier }
        guard matches.count == 1, let current = matches.first,
              current.displayID == monitor.displayID, current.bounds == monitor.bounds else {
            throw MonitorSelectionFailure("\(monitor.name) disconnected or changed during setup. Start setup again to use the current monitor selection.")
        }
        return current
    }
}

struct MonitorSelectionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
