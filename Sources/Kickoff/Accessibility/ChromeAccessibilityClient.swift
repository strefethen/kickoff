import AppKit
import ApplicationServices
import Foundation

protocol ChromeAccessibilityAccessing: AnyObject {
    var pid: pid_t { get }
    var application: AXUIElement { get }
    func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef?
    func text(_ element: AXUIElement, _ name: String) throws -> String
    func windows() throws -> [AXUIElement]
    func isMinimized(_ window: AXUIElement) throws -> Bool
    func inspect(
        _ root: AXUIElement,
        maximumNodes: Int,
        maximumDepth: Int,
        timeout: TimeInterval,
        stopDescending: (AccessibilityNode) -> Bool
    ) throws -> [AccessibilityNode]
    func advertisedActions(_ element: AXUIElement) throws -> [String]
    func performOnce(_ action: String, on element: AXUIElement) -> AXError
}

/// Owns Chrome process binding plus bounded, generic AX reads and actions.
/// Hulu player semantics live in `HuluPlayerClient`.
final class ChromeAccessibilityClient: ChromeAccessibilityAccessing {
    let pid: pid_t
    let application: AXUIElement

    init() throws {
        guard AXIsProcessTrusted() else {
            throw AccessibilityFailure("Accessibility permission is missing. Enable Kickoff in System Settings > Privacy & Security > Accessibility.")
        }
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
        guard matches.count == 1, let chrome = matches.first else {
            throw AccessibilityFailure("Expected one running Google Chrome process; found \(matches.count).")
        }
        pid = chrome.processIdentifier
        application = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        guard result == .success else {
            throw AccessibilityFailure("AX timeout setup failed: \(result.rawValue).", axError: result)
        }
    }

    func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        switch error {
        case .success:
            return result
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw AccessibilityFailure("Reading \(name) failed: AX error \(error.rawValue).", axError: error)
        }
    }

    func text(_ element: AXUIElement, _ name: String) throws -> String {
        guard let value = try attribute(element, name) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }

    func windows() throws -> [AXUIElement] {
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false,
              let windows = try attribute(application, kAXWindowsAttribute) as? [AXUIElement] else {
            throw AccessibilityFailure("Chrome exited or did not expose its windows.")
        }
        return windows
    }

    func isMinimized(_ window: AXUIElement) throws -> Bool {
        try attribute(window, kAXMinimizedAttribute) as? Bool == true
    }

    func inspect(
        _ root: AXUIElement,
        maximumNodes: Int = 2_000,
        maximumDepth: Int = 50,
        timeout: TimeInterval = 8,
        stopDescending: (AccessibilityNode) -> Bool = { _ in false }
    ) throws -> [AccessibilityNode] {
        let deadline = Date().addingTimeInterval(timeout)
        var pending: [(AXUIElement, Int, Bool)] = [(root, 0, false)]
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var nodes: [AccessibilityNode] = []

        while let (element, depth, ancestorHidden) = pending.popLast() {
            guard Date() < deadline, nodes.count < maximumNodes, depth <= maximumDepth else {
                throw AccessibilityFailure("AX traversal limit reached; results are incomplete.")
            }
            let hash = CFHash(element)
            if visited[hash, default: []].contains(where: { CFEqual($0, element) }) { continue }
            visited[hash, default: []].append(element)

            let rawURL = try attribute(element, kAXURLAttribute)
            let url = (rawURL as? URL)?.absoluteString ?? rawURL as? String
            let ownHidden = try attribute(element, "AXHidden") as? Bool == true
            let hidden = ancestorHidden || ownHidden
            let node = AccessibilityNode(
                element: element,
                role: try text(element, kAXRoleAttribute),
                title: try text(element, kAXTitleAttribute),
                nodeDescription: try text(element, kAXDescriptionAttribute),
                value: try text(element, kAXValueAttribute),
                valueDescription: try text(element, kAXValueDescriptionAttribute),
                url: url,
                domIdentifier: try text(element, "AXDOMIdentifier"),
                hidden: hidden,
                depth: depth
            )
            nodes.append(node)
            if stopDescending(node) { continue }

            let children = try attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard children.count <= maximumNodes else {
                throw AccessibilityFailure("AX element exposed too many children.")
            }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1, hidden) })
        }
        return nodes
    }

    func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws {
        var settable = DarwinBoolean(false)
        let query = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard query == .success, settable.boolValue else {
            throw AccessibilityFailure("Chrome does not allow setting \(attribute).")
        }
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard result == .success else {
            throw AccessibilityFailure("Setting \(attribute) failed: \(result.rawValue). Inspect before retrying.", axError: result)
        }
    }

    func advertisedActions(_ element: AXUIElement) throws -> [String] {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success else {
            throw AccessibilityFailure("Reading AX actions failed: \(result.rawValue).", axError: result)
        }
        return actions as? [String] ?? []
    }

    @discardableResult
    func performOnce(_ action: String, on element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }
}
