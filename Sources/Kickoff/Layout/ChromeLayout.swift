import AppKit
import ApplicationServices
import CAXNavigation
import Foundation

/// Native AX setup. Each run owns only the new Chrome window it creates.
final class ChromeLayout {
    let chrome: ChromeAccessibilityClient
    let monitor: Monitor
    private let target: MonitorTarget
    private let website: WebsiteURL
    private var ownedWindow: AXUIElement?
    private let layoutTerminals: Set<String> = [
        "AXWebArea", kAXTextFieldRole, kAXButtonRole, kAXRadioButtonRole,
        kAXSliderRole, kAXStaticTextRole, kAXImageRole, "AXLink",
        kAXPopUpButtonRole, kAXMenuItemRole,
    ]

    init(target: MonitorTarget, website: WebsiteURL, chrome: ChromeAccessibilityClient? = nil) throws {
        self.target = target
        self.monitor = target.monitor
        self.website = website
        self.chrome = try chrome ?? ChromeAccessibilityClient()
    }

    func rect(_ element: AXUIElement) throws -> CGRect {
        guard let positionValue = try chrome.attribute(element, kAXPositionAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = try chrome.attribute(element, kAXSizeAttribute),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw AccessibilityFailure("Chrome did not expose the requested geometry.")
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            throw AccessibilityFailure("Chrome geometry could not be decoded.")
        }
        return CGRect(origin: point, size: size)
    }

    func log(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    func currentTargetWindow() throws -> ChromeWindowSnapshot {
        let display = try target.validate()
        let windows = try chrome.windows()
        let element: AXUIElement
        if let ownedWindow {
            guard windows.contains(where: { CFEqual($0, ownedWindow) }) else {
                throw AccessibilityFailure("The setup window disappeared.")
            }
            element = ownedWindow
        } else {
            guard windows.count == 1, let only = windows.first else {
                throw AccessibilityFailure("This diagnostic command requires one Chrome window.")
            }
            element = only
            ownedWindow = only
        }
        guard display.bounds.contains(try rect(element)) else {
            throw AccessibilityFailure("The setup window is no longer on \(monitor.name).")
        }
        let nodes = try chrome.inspect(element, stopDescending: { self.layoutTerminals.contains($0.role) })
        return ChromeWindowSnapshot(
            element: element,
            index: 0,
            title: try chrome.text(element, kAXTitleAttribute),
            nodes: nodes
        )
    }

    @discardableResult
    func prepare() throws -> ChromeWindowSnapshot {
        _ = try target.validate()
        let before = try chrome.windows()
        try performAction(kAXPressAction, on: newWindowCommand())
        let deadline = Date().addingTimeInterval(8)
        repeat {
            let created = try chrome.windows().filter { candidate in
                !before.contains(where: { CFEqual($0, candidate) })
            }
            guard created.count <= 1 else {
                throw AccessibilityFailure("Multiple new Chrome windows appeared; setup stopped.")
            }
            if let window = created.first {
                ownedWindow = window
                let current = try target.validate()
                try applyFrame(current.visibleBounds.insetBy(dx: 24, dy: 24), to: window)
                log(["event": "window-on-monitor", "chromePID": chrome.pid, "display": monitor.name])
                return try waitForWindow(seconds: 8) { self.pageURLs($0).count == 1 }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        throw AccessibilityFailure("Chrome did not create a new window.")
    }

    func browseActiveWebsite(expectedPages: Int) throws {
        let original = try currentTargetWindow()
        let fields = original.nodes.filter {
            $0.role == kAXTextFieldRole && $0.nodeDescription == "Address and search bar"
        }
        guard fields.count == 1, let field = fields.first else {
            throw AccessibilityFailure("Chrome's address bar is ambiguous.")
        }
        try submitWebsite(in: original.element, addressField: field.element)
        let loaded: ChromeWindowSnapshot
        do {
            loaded = try waitForWindow(seconds: 20) {
                let urls = self.pageURLs($0)
                return urls.count == expectedPages && urls.allSatisfy(self.website.acceptsLoadedURL)
            }
        } catch {
            let urls = (try? currentTargetWindow()).map(pageURLs) ?? []
            if urls.count == expectedPages, let failure = website.redirectFailure(for: urls) {
                throw AccessibilityFailure(failure)
            }
            throw error
        }
        log(["event": "website-verified", "urls": pageURLs(loaded), "chromePID": chrome.pid])
    }

    func split() throws {
        let window = try currentTargetWindow()
        guard pageURLs(window).count == 1 else {
            throw AccessibilityFailure("Split creation requires a single page.")
        }
        let buttons = window.nodes.filter { $0.role == kAXButtonRole && $0.title == "Open tab in split view" }
        guard buttons.count == 1, let button = buttons.first else {
            throw AccessibilityFailure("Chrome's split-view button is unavailable.")
        }
        try performAction(kAXPressAction, on: button.element)
        _ = try waitForWindow(seconds: 8) {
            self.hasSplit($0) && self.pageURLs($0).count == 2 &&
                $0.nodes.contains { $0.title == "Arrange split view - right view active" }
        }
        log(["event": "split-verified", "chromePID": chrome.pid])
    }

    func enterFullScreen() throws {
        let window = try currentTargetWindow()
        let expected = try target.validate().bounds
        guard let isFullScreen = try chrome.attribute(window.element, "AXFullScreen") as? Bool else {
            throw AccessibilityFailure("Chrome's full-screen state is unavailable.")
        }
        if !isFullScreen {
            guard let rawButton = try chrome.attribute(window.element, kAXFullScreenButtonAttribute),
                  CFGetTypeID(rawButton) == AXUIElementGetTypeID() else {
                throw AccessibilityFailure("Chrome's full-screen button is unavailable.")
            }
            try performAction(kAXPressAction, on: rawButton as! AXUIElement)
        }
        _ = try waitForWindow(seconds: 8) {
            try self.chrome.attribute($0.element, "AXFullScreen") as? Bool == true &&
                self.matchesFrame(try self.rect($0.element), expected)
        }
        log(["event": "full-screen-verified", "display": monitor.name, "chromePID": chrome.pid])
    }

    func setup() throws {
        try step("Create window on \(monitor.name)") { _ = try prepare() }
        try step("Load first website page") { try browseActiveWebsite(expectedPages: 1) }
        try step("Create split view") { try split() }
        try step("Load second website page") { try browseActiveWebsite(expectedPages: 2) }
        try step("Enter full screen") { try enterFullScreen() }
        let final = try currentTargetWindow()
        let finalURLs = pageURLs(final)
        guard hasSplit(final), finalURLs.count == 2 else {
            throw AccessibilityFailure("Final Chrome layout could not be verified.")
        }
        if let failure = website.redirectFailure(for: finalURLs) {
            throw AccessibilityFailure(failure)
        }
        log(["event": "setup-complete", "chromePID": chrome.pid, "display": monitor.name, "urls": finalURLs])
    }

    func environment() throws -> [String: Any] {
        let display = try target.validate()
        return [
            "chromePID": chrome.pid,
            "display": monitor.name,
            "displayUUID": monitor.identifier,
            "displayID": display.displayID,
            "displayBounds": NSStringFromRect(display.bounds),
            "windows": try chrome.windows().map { element in
                ["title": try chrome.text(element, kAXTitleAttribute), "bounds": NSStringFromRect(try rect(element))]
            },
        ]
    }

    private func waitForWindow(
        seconds: Double,
        until condition: (ChromeWindowSnapshot) throws -> Bool
    ) throws -> ChromeWindowSnapshot {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            do {
                let window = try currentTargetWindow()
                if try condition(window) { return window }
            } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                // Page descendants are replaced while loading. The owning
                // window is checked again on the next bounded read.
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        throw AccessibilityFailure("Chrome did not finish the setup step. No action was repeated.")
    }

    private func applyFrame(_ frame: CGRect, to window: AXUIElement) throws {
        _ = try target.validate()
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw AccessibilityFailure("Could not encode window frame.")
        }
        try chrome.set(window, attribute: kAXPositionAttribute, value: positionValue)
        try chrome.set(window, attribute: kAXSizeAttribute, value: sizeValue)
        guard matchesFrame(try rect(window), frame) else {
            throw AccessibilityFailure("Chrome did not take the requested window size.")
        }
    }

    private func matchesFrame(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1 &&
            abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
    }

    private func children(_ element: AXUIElement) throws -> [AXUIElement] {
        guard let children = try chrome.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            throw AccessibilityFailure("Chrome's required menu children are unavailable.")
        }
        return children
    }

    private func uniqueChild(_ parent: AXUIElement, role: String, title: String? = nil) throws -> AXUIElement {
        let matches = try children(parent).filter { child in
            guard try chrome.text(child, kAXRoleAttribute) == role else { return false }
            return try title == nil || chrome.text(child, kAXTitleAttribute) == title
        }
        guard matches.count == 1, let match = matches.first else {
            throw AccessibilityFailure("Chrome menu item \(title ?? role) is unavailable or ambiguous.")
        }
        return match
    }

    private func newWindowCommand() throws -> AXUIElement {
        guard let rawMenu = try chrome.attribute(chrome.application, kAXMenuBarAttribute),
              CFGetTypeID(rawMenu) == AXUIElementGetTypeID() else {
            throw AccessibilityFailure("Chrome's menu bar is unavailable.")
        }
        let file = try uniqueChild(rawMenu as! AXUIElement, role: kAXMenuBarItemRole, title: "File")
        let menu = try uniqueChild(file, role: kAXMenuRole)
        return try uniqueChild(menu, role: kAXMenuItemRole, title: "New Window")
    }

    private func pageURLs(_ window: ChromeWindowSnapshot) -> [String] {
        let areas = window.nodes.filter { $0.role == "AXWebArea" }
        guard let depth = areas.map(\.depth).min() else { return [] }
        return areas.filter { $0.depth == depth }.compactMap(\.url)
    }

    private func submitWebsite(in window: AXUIElement, addressField: AXUIElement) throws {
        let submit = {
            _ = try self.target.validate()
            try self.chrome.set(self.chrome.application, attribute: kAXFrontmostAttribute, value: kCFBooleanTrue)
            let deadline = Date().addingTimeInterval(4)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != self.chrome.pid && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.chrome.pid else {
                throw AccessibilityFailure("Chrome did not become the foreground app. No Return was sent.")
            }
            try self.chrome.set(addressField, attribute: kAXFocusedAttribute, value: kCFBooleanTrue)
            try self.chrome.set(addressField, attribute: kAXValueAttribute, value: self.website.absoluteString as CFString)
            guard try self.chrome.windows().contains(where: { CFEqual($0, window) }),
                  try self.target.validate().bounds.contains(self.rect(window)),
                  let focus = try self.chrome.attribute(self.chrome.application, kAXFocusedUIElementAttribute),
                  CFEqual(focus, addressField),
                  let focusedWindow = try self.chrome.attribute(self.chrome.application, kAXFocusedWindowAttribute),
                  CFEqual(focusedWindow, window),
                  self.website.matchesPendingAddress(try self.chrome.text(addressField, kAXValueAttribute)),
                  try self.chrome.attribute(self.chrome.application, kAXFrontmostAttribute) as? Bool == true,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.chrome.pid else {
                throw AccessibilityFailure("The foreground website address field changed. No Return was sent.")
            }
            let result = HuluAXReturnToFrontmost()
            self.log(["event": "submit-website", "api": "AXUIElementPostKeyboardEvent", "result": result.rawValue])
        }
        if Thread.isMainThread { try submit() }
        else { try DispatchQueue.main.sync(execute: submit) }
    }

    private func performAction(_ action: String, on element: AXUIElement) throws {
        _ = try target.validate()
        guard try chrome.attribute(element, kAXEnabledAttribute) as? Bool == true,
              try chrome.advertisedActions(element).contains(action) else {
            throw AccessibilityFailure("Chrome's requested control is not available.")
        }
        let result = chrome.performOnce(action, on: element)
        log(["event": action, "result": result.rawValue])
    }

    private func hasSplit(_ window: ChromeWindowSnapshot) -> Bool {
        let tabs = window.nodes.filter {
            $0.role == kAXRadioButtonRole &&
                ($0.nodeDescription.contains(" - Left view") || $0.nodeDescription.contains(" - Right view"))
        }
        return tabs.count == 2 && window.nodes.filter {
            $0.nodeDescription.hasPrefix("Split View Resize Handle")
        }.count == 1
    }

    private func step(_ name: String, action: () throws -> Void) throws {
        log(["event": "setup-step", "step": name])
        do { try action() }
        catch { throw AccessibilityFailure("\(name): \(error)") }
    }
}
