import AppKit
import ApplicationServices
import Foundation

protocol ChromeLayoutAccessing: ChromeAccessibilityAccessing, ChromeAddressFieldAccessing {}

extension ChromeAccessibilityClient: ChromeLayoutAccessing {}

/// Native AX setup. Each run owns only the new Chrome window it creates.
final class ChromeLayout {
    let chrome: ChromeLayoutAccessing
    let monitor: Monitor
    private let target: MonitorTarget
    private let website: WebsiteURL
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let windowStateTimeout: TimeInterval
    private var ownedWindow: AXUIElement?
    private let layoutTerminals: Set<String> = [
        "AXWebArea", kAXTextFieldRole, kAXButtonRole, kAXRadioButtonRole,
        kAXSliderRole, kAXStaticTextRole, kAXImageRole, "AXLink",
        kAXPopUpButtonRole, kAXMenuItemRole,
    ]

    init(
        target: MonitorTarget,
        website: WebsiteURL,
        chrome: ChromeLayoutAccessing? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep,
        windowStateTimeout: TimeInterval = 8
    ) throws {
        self.target = target
        self.monitor = target.monitor
        self.website = website
        self.chrome = try chrome ?? ChromeAccessibilityClient()
        self.now = now
        self.sleep = sleep
        self.windowStateTimeout = windowStateTimeout
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
        return try snapshot(element)
    }

    @discardableResult
    func prepare(frame: CGRect? = nil) throws -> ChromeWindowSnapshot {
        _ = try target.validate()
        let before = try chrome.windows()
        try performAction(kAXPressAction, on: newWindowCommand())
        let deadline = now().addingTimeInterval(8)
        repeat {
            let created = try chrome.windows().filter { candidate in
                !before.contains(where: { CFEqual($0, candidate) })
            }
            guard created.count <= 1 else {
                throw AccessibilityFailure("Multiple new Chrome windows appeared; setup stopped.")
            }
            if let window = created.first {
                ownedWindow = window
                let requestedFrame = frame ?? target.monitor.visibleBounds.insetBy(dx: 24, dy: 24)
                try applyNormalFrame(requestedFrame, to: window, moveBeforeResize: true)
                log(["event": "window-on-monitor", "chromePID": chrome.pid, "display": monitor.name])
                return try waitForWindow(seconds: 8) { self.pageURLs($0).count == 1 }
            }
            sleep(0.2)
        } while now() < deadline
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
        try waitForOwnedWindowFullScreen(window.element, expected: expected)
        log(["event": "full-screen-verified", "display": monitor.name, "chromePID": chrome.pid])
    }

    func setup() throws {
        try configureSplitWindow(frame: nil)
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

    func setupSplitWindow(frame: CGRect) throws {
        try configureSplitWindow(frame: frame)
    }

    private func configureSplitWindow(frame: CGRect?) throws {
        try step("Create window on \(monitor.name)") { _ = try prepare(frame: frame) }
        try step("Load first website page") { try browseActiveWebsite(expectedPages: 1) }
        try step("Create split view") { try split() }
        try step("Load second website page") { try browseActiveWebsite(expectedPages: 2) }
    }

    func verifySplitWindow(frame: CGRect) throws {
        _ = try waitForOwnedSplitWindow(frame: frame)
    }

    func measuredBrowserInsets() throws -> ChromeBrowserInsets {
        let deadline = now().addingTimeInterval(windowStateTimeout)
        repeat {
            do {
                let snapshot = try waitForOwnedSplitWindow(frame: nil)
                let windowFrame = try rect(snapshot.element)
                let areas = pageAreas(snapshot)
                let pageFrames = try areas.map { try rect($0.element) }
                if pageFrames.count == 2,
                   pageFrames.allSatisfy({ windowFrame.insetBy(dx: -1, dy: -1).contains($0) }),
                   abs(pageFrames[0].minY - pageFrames[1].minY) <= 1,
                   abs(pageFrames[0].maxY - pageFrames[1].maxY) <= 1 {
                    let top = pageFrames[0].minY - windowFrame.minY
                    let bottom = windowFrame.maxY - pageFrames[0].maxY
                    if top.isFinite, bottom.isFinite, top >= 0, bottom >= 0 {
                        return ChromeBrowserInsets(top: top, bottom: bottom)
                    }
                }
            } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                // Re-read this owned window while its page renderers resize.
            }
            // Chrome publishes the outer frame before its split viewports.
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure("Chrome's split website viewports did not settle into one vertical frame inside the setup window.")
    }

    func placeWindow(frame: CGRect) throws {
        guard let window = ownedWindow else {
            throw AccessibilityFailure("Chrome window placement requires the window created by this setup session.")
        }
        try applyNormalFrame(frame, to: window)
    }

    func raiseWindow() throws {
        guard let window = ownedWindow else {
            throw AccessibilityFailure("Chrome window raising requires the window created by this setup session.")
        }
        _ = try target.validate()
        guard try chrome.windows().contains(where: { CFEqual($0, window) }),
              try chrome.advertisedActions(window).contains(kAXRaiseAction) else {
            throw AccessibilityFailure("Chrome's setup window cannot be raised.")
        }
        let result = chrome.performOnce(kAXRaiseAction, on: window)
        log(["event": kAXRaiseAction, "result": result.rawValue])
        guard result == .success else {
            throw AccessibilityFailure("Raising Chrome's setup window failed with AX error \(result.rawValue).", axError: result)
        }

        let deadline = now().addingTimeInterval(windowStateTimeout)
        repeat {
            _ = try target.validate()
            let windows = try chrome.windows()
            if windows.contains(where: { CFEqual($0, window) }) {
                do {
                    let mainWindow = try chrome.attribute(chrome.application, kAXMainWindowAttribute)
                    let focusedWindow = try chrome.attribute(chrome.application, kAXFocusedWindowAttribute)
                    if isElement(mainWindow, equalTo: window), isElement(focusedWindow, equalTo: window) {
                        return
                    }
                } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                    // Retry the same owned window while Chrome updates focus.
                }
            }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure("Chrome did not make the raised setup window main and focused.")
    }

    private func waitForOwnedSplitWindow(frame: CGRect?) throws -> ChromeWindowSnapshot {
        guard let window = ownedWindow else {
            throw AccessibilityFailure("Chrome split verification requires the window created by this setup session.")
        }
        let deadline = now().addingTimeInterval(windowStateTimeout)
        repeat {
            let display = try target.validate()
            let windows = try chrome.windows()
            if windows.contains(where: { CFEqual($0, window) }) {
                do {
                    guard let isFullScreen = try chrome.attribute(window, "AXFullScreen") as? Bool else {
                        throw AccessibilityFailure("Chrome's full-screen state is unavailable.")
                    }
                    let actualFrame = try rect(window)
                    let frameMatches = frame.map { matchesFrame(actualFrame, $0) } ?? true
                    if !isFullScreen, display.bounds.contains(actualFrame), frameMatches {
                        let snapshot = try snapshot(window)
                        let urls = pageURLs(snapshot)
                        if hasSplit(snapshot), urls.count == 2,
                           urls.allSatisfy(website.acceptsLoadedURL) {
                            return snapshot
                        }
                    }
                } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                    // Chrome may replace descendants during navigation. The
                    // same owning window is checked again on the next read.
                }
            }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure(
            frame.map {
                "Chrome did not keep the setup window at \(NSStringFromRect($0)) in normal split view with two loaded website pages."
            } ?? "Chrome did not keep the owned setup window in normal split view with two loaded website pages."
        )
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
        let deadline = now().addingTimeInterval(seconds)
        repeat {
            do {
                let window = try currentTargetWindow()
                if try condition(window) { return window }
            } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                // Page descendants are replaced while loading. The owning
                // window is checked again on the next bounded read.
            }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure("Chrome did not finish the setup step. No action was repeated.")
    }

    private func waitForOwnedWindowFullScreen(_ window: AXUIElement, expected: CGRect) throws {
        let deadline = now().addingTimeInterval(windowStateTimeout)
        repeat {
            let display = try target.validate()
            let windows = try chrome.windows()
            let isOwnedWindowListed = windows.contains { CFEqual($0, window) }
            if isOwnedWindowListed {
                do {
                    guard let isFullScreen = try chrome.attribute(window, "AXFullScreen") as? Bool else {
                        throw AccessibilityFailure("Chrome's full-screen state is unavailable.")
                    }
                    let frame = try rect(window)
                    guard display.bounds.contains(frame) else {
                        throw AccessibilityFailure("The setup window is no longer on \(monitor.name).")
                    }
                    if isFullScreen, matchesFrame(frame, expected) { return }
                } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                    // Chrome may briefly invalidate the listed element while
                    // moving that same window into its full-screen space.
                }
            }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure("Chrome did not finish the setup step. No action was repeated.")
    }

    private func applyNormalFrame(_ frame: CGRect, to window: AXUIElement, moveBeforeResize: Bool = false) throws {
        let display = try target.validate()
        guard display.bounds.contains(frame) else {
            throw AccessibilityFailure("The requested window frame is outside \(monitor.name).")
        }
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw AccessibilityFailure("Could not encode window frame.")
        }
        if moveBeforeResize {
            // New windows inherit another monitor's origin. Move onto the
            // target before expanding so macOS does not clamp the new size.
            try chrome.set(window, attribute: kAXPositionAttribute, value: positionValue)
            try chrome.set(window, attribute: kAXSizeAttribute, value: sizeValue)
        } else {
            // Shrink an already placed window before moving it down, so its
            // old height does not cause macOS to clamp the lower-row origin.
            try chrome.set(window, attribute: kAXSizeAttribute, value: sizeValue)
            try chrome.set(window, attribute: kAXPositionAttribute, value: positionValue)
        }
        try waitForOwnedWindowNormalFrame(window, expected: frame)
    }

    private func waitForOwnedWindowNormalFrame(_ window: AXUIElement, expected: CGRect) throws {
        let deadline = now().addingTimeInterval(windowStateTimeout)
        repeat {
            let display = try target.validate()
            let windows = try chrome.windows()
            if windows.contains(where: { CFEqual($0, window) }) {
                do {
                    guard let isFullScreen = try chrome.attribute(window, "AXFullScreen") as? Bool else {
                        throw AccessibilityFailure("Chrome's full-screen state is unavailable.")
                    }
                    let actualFrame = try rect(window)
                    if !isFullScreen, display.bounds.contains(actualFrame), matchesFrame(actualFrame, expected) { return }
                } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                    // The same owning window is checked again after a short
                    // bounded delay if Chrome transiently invalidates it.
                }
            }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure(
            "Chrome did not place the setup window at \(NSStringFromRect(expected)) in normal mode."
        )
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
        pageAreas(window).compactMap(\.url)
    }

    private func pageAreas(_ window: ChromeWindowSnapshot) -> [AccessibilityNode] {
        let areas = window.nodes.filter { $0.role == "AXWebArea" }
        guard let depth = areas.map(\.depth).min() else { return [] }
        return areas.filter { $0.depth == depth }
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
            let entry = ChromeAddressEntry(
                chrome: self.chrome,
                addressField: addressField,
                expected: self.website.absoluteString,
                validateRecipient: {
                    guard try self.chrome.windows().contains(where: { CFEqual($0, window) }),
                          try self.target.validate().bounds.contains(self.rect(window)),
                          let focus = try self.chrome.attribute(self.chrome.application, kAXFocusedUIElementAttribute),
                          CFEqual(focus, addressField),
                          let focusedWindow = try self.chrome.attribute(self.chrome.application, kAXFocusedWindowAttribute),
                          CFEqual(focusedWindow, window),
                          try self.chrome.attribute(self.chrome.application, kAXFrontmostAttribute) as? Bool == true,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == self.chrome.pid else {
                        throw AccessibilityFailure("The foreground website address field changed; submission stopped.")
                    }
                },
                logKeyResult: { event, result in
                    self.log(["event": event, "api": "AXUIElementPostKeyboardEvent", "result": result.rawValue])
                }
            )
            try entry.submit()
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

    private func snapshot(_ window: AXUIElement) throws -> ChromeWindowSnapshot {
        let nodes = try chrome.inspect(
            window,
            maximumNodes: 2_000,
            maximumDepth: 50,
            timeout: 8,
            stopDescending: { self.layoutTerminals.contains($0.role) }
        )
        return ChromeWindowSnapshot(
            element: window,
            index: 0,
            title: try chrome.text(window, kAXTitleAttribute),
            nodes: nodes
        )
    }

    private func isElement(_ value: CFTypeRef?, equalTo expected: AXUIElement) -> Bool {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return CFEqual(value, expected)
    }

    private func step(_ name: String, action: () throws -> Void) throws {
        log(["event": "setup-step", "step": name])
        do { try action() }
        catch { throw AccessibilityFailure("\(name): \(error)") }
    }
}
