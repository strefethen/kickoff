import AppKit
import ApplicationServices
import Foundation

protocol ChromeLayoutAccessing: ChromeAccessibilityAccessing, ChromeAddressFieldAccessing {}

extension ChromeAccessibilityClient: ChromeLayoutAccessing {}

enum ChromeViewClass {
    static let omnibox = "OmniboxViewViews"
    static let splitButton = "SplitTabsToolbarButton"
    static let splitResizeHandle = "MultiContentsResizeHandle"
    static let tab = "Tab"
}

/// Native AX setup. Each run owns only the new Chrome window it creates.
final class ChromeLayout {
    let chrome: ChromeLayoutAccessing
    let monitor: Monitor
    private let target: MonitorTarget
    private let website: WebsiteURL
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let windowStateTimeout: TimeInterval
    private let setupLog: SetupLogging?
    private let scripting: ChromeWindowScripting
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
        windowStateTimeout: TimeInterval = 8,
        setupLog: SetupLogging? = nil,
        scripting: ChromeWindowScripting
    ) throws {
        self.target = target
        self.monitor = target.monitor
        self.website = website
        self.chrome = try chrome ?? ChromeAccessibilityClient()
        self.now = now
        self.sleep = sleep
        self.windowStateTimeout = windowStateTimeout
        self.setupLog = setupLog
        self.scripting = scripting
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
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let line = String(decoding: data, as: UTF8.self)
        print(line)
        fflush(stdout)
        setupLog?.record(line)
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
        let requestedFrame = frame ?? target.monitor.visibleBounds.insetBy(dx: 24, dy: 24)
        let before = try readyWindows()
        let scriptID = try requestWindow(at: requestedFrame)
        log(["event": "window-requested", "chromeWindowID": scriptID, "frame": NSStringFromRect(requestedFrame)])
        let window: AXUIElement
        do {
            window = try pairRequestedWindow(at: requestedFrame, excluding: before)
        } catch {
            do {
                try scripting.closeWindow(id: scriptID)
                log(["event": "close-requested-window", "chromeWindowID": scriptID])
            } catch let closeError {
                throw ChromeWindowLeftOpen(description: "\(error) Kickoff also could not close the window it requested: \(closeError)")
            }
            throw AccessibilityFailure("\(error) Kickoff closed the window it requested.")
        }
        ownedWindow = window
        try applyNormalFrame(requestedFrame, to: window, moveBeforeResize: true)
        log(["event": "window-on-monitor", "chromePID": chrome.pid, "display": monitor.name])
        return try waitForWindow(seconds: windowStateTimeout) { _ in true }
    }

    private func pairRequestedWindow(at frame: CGRect, excluding before: [AXUIElement]) throws -> AXUIElement {
        let deadline = now().addingTimeInterval(windowStateTimeout)
        var created: [AXUIElement] = []
        repeat {
            created = try chrome.windows().filter { candidate in
                !before.contains(where: { CFEqual($0, candidate) })
            }
            let placed = created.filter { isNewWindow($0, at: frame) }
            guard placed.count <= 1 else {
                throw AccessibilityFailure("Several new Chrome windows appeared at the setup position, so Kickoff could not tell which one it opened.")
            }
            if let window = placed.first { return window }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure("Chrome did not open the requested window at \(NSStringFromRect(frame)) (\(created.count) new windows appeared).")
    }

    private func readyWindows() throws -> [AXUIElement] {
        let deadline = now().addingTimeInterval(2)
        while true {
            do {
                return try chrome.windows()
            } catch let failure as AccessibilityFailure
                where failure.axError == .cannotComplete || failure.axError == .invalidUIElement {
                guard now() < deadline else { throw failure }
                sleep(0.1)
            }
        }
    }

    private func requestWindow(at frame: CGRect) throws -> String {
        let deadline = now().addingTimeInterval(windowStateTimeout)
        while true {
            do {
                return try scripting.makeWindow(bounds: frame)
            } catch let failure as ChromeScriptingFailure where failure.kind == .notReady {
                guard now() < deadline else { throw failure }
                sleep(0.2)
            }
        }
    }

    private func isNewWindow(_ window: AXUIElement, at frame: CGRect) -> Bool {
        guard let actual = try? rect(window) else { return false }
        return matchesFrame(actual, frame)
    }

    func browseActiveWebsite(expectedPages: Int) throws {
        let original = try currentTargetWindow()
        let fields = original.nodes.filter {
            $0.role == kAXTextFieldRole && $0.domClassList.contains(ChromeViewClass.omnibox)
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
        let buttons = window.nodes.filter { $0.role == kAXButtonRole && $0.domClassList.contains(ChromeViewClass.splitButton) }
        guard buttons.count == 1, let button = buttons.first else {
            throw AccessibilityFailure("Chrome's split-view button is unavailable. Update Google Chrome to a version with split view.")
        }
        try performAction(kAXPressAction, on: button.element)
        _ = try waitForWindow(seconds: 8) {
            self.hasSplit($0) && self.pageURLs($0).count == 2
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

    func setupSingleWindow() throws {
        try step("Create window on \(monitor.name)") { _ = try prepare() }
        try step("Load website page") { try browseActiveWebsite(expectedPages: 1) }
        try step("Enter full screen") { try enterFullScreen() }
        let final = try currentTargetWindow()
        let finalURLs = pageURLs(final)
        guard !hasSplit(final), finalURLs.count == 1 else {
            throw AccessibilityFailure("Final single-window Chrome layout could not be verified.")
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

    func focusOwnedWindowForSubmission() throws {
        guard let window = ownedWindow else {
            throw AccessibilityFailure("Website submission requires the window created by this setup session.")
        }
        if isElement(try chrome.attribute(chrome.application, kAXFocusedWindowAttribute), equalTo: window) { return }
        log(["event": "setup-window-not-focused"])
        try raiseWindow()
    }

    func closeOwnedWindow() throws -> Bool {
        guard let window = ownedWindow else { return false }
        let listedDeadline = now().addingTimeInterval(min(windowStateTimeout, 3))
        while try !chrome.windows().contains(where: { CFEqual($0, window) }) {
            guard now() < listedDeadline else {
                throw AccessibilityFailure("Chrome stopped listing the setup window, so Kickoff could not confirm it closed. Check \(monitor.name) for a leftover window.")
            }
            sleep(0.2)
        }
        guard let rawButton = try chrome.attribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(rawButton) == AXUIElementGetTypeID() else {
            throw AccessibilityFailure("Chrome's close button for the setup window is unavailable.")
        }
        let result = chrome.performOnce(kAXPressAction, on: rawButton as! AXUIElement)
        log(["event": "close-owned-window", "result": result.rawValue])
        guard result == .success else {
            throw AccessibilityFailure("Closing the setup window failed with AX error \(result.rawValue).", axError: result)
        }
        let deadline = now().addingTimeInterval(min(windowStateTimeout, 3))
        repeat {
            if try !chrome.windows().contains(where: { CFEqual($0, window) }) {
                ownedWindow = nil
                return true
            }
            sleep(0.2)
        } while now() < deadline
        throw AccessibilityFailure("Chrome kept the setup window open, possibly because a page asked to confirm leaving.")
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

    private enum FrameWriteOrder {
        case moveThenResize
        case resizeThenMove
    }

    private struct NormalFrameObservation {
        let frame: CGRect?
        let isFullScreen: Bool?
        let isListed: Bool

        func matches(_ expected: CGRect, on display: CGRect) -> Bool {
            guard isListed, isFullScreen == false, let frame else { return false }
            return display.contains(frame) && Self.matchesFrame(frame, expected)
        }

        var summary: String {
            guard isListed else { return "the window was no longer listed" }
            let place = frame.map(NSStringFromRect) ?? "an unreadable frame"
            return isFullScreen == true ? "it was full screen at \(place)" : "it was at \(place)"
        }

        static func matchesFrame(_ actual: CGRect, _ expected: CGRect) -> Bool {
            abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1 &&
                abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
        }
    }

    private static let frameSettleInterval: TimeInterval = 0.2

    private func applyNormalFrame(_ frame: CGRect, to window: AXUIElement, moveBeforeResize: Bool = false) throws {
        let display = try target.validate()
        guard display.bounds.contains(frame) else {
            throw AccessibilityFailure("The requested window frame is outside \(monitor.name).")
        }
        let order: FrameWriteOrder = moveBeforeResize ? .moveThenResize : .resizeThenMove
        let deadline = now().addingTimeInterval(windowStateTimeout)
        var attempts = 0
        var observed = try observeNormalFrame(window)
        repeat {
            if observed.isListed {
                do {
                    try writeFrame(frame, to: window, current: observed.frame, order: order)
                } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
                    log(["event": "frame-write-invalid-element", "attempt": attempts + 1])
                }
                attempts += 1
            }
            var previousFrame: CGRect?
            var reads = 0
            repeat {
                if reads > 0 { sleep(Self.frameSettleInterval) }
                reads += 1
                observed = try observeNormalFrame(window)
                if observed.matches(frame, on: try target.validate().bounds) {
                    log(["event": "frame-verified", "frame": NSStringFromRect(frame), "attempts": attempts])
                    return
                }
                if let current = observed.frame, current == previousFrame { break }
                previousFrame = observed.frame
            } while now() < deadline
            log(["event": "frame-mismatch", "expected": NSStringFromRect(frame), "observed": observed.summary, "attempt": attempts])
        } while now() < deadline
        throw AccessibilityFailure(
            "Chrome would not keep the setup window at \(NSStringFromRect(frame)) on \(monitor.name); after \(attempts) attempts \(observed.summary)."
        )
    }

    private func writeFrame(_ frame: CGRect, to window: AXUIElement, current: CGRect?, order: FrameWriteOrder) throws {
        switch order {
        case .moveThenResize:
            if let current, current.width > frame.width || current.height > frame.height {
                try setSize(CGSize(width: min(current.width, frame.width), height: min(current.height, frame.height)), of: window)
            }
            try setPosition(frame.origin, of: window)
            try setSize(frame.size, of: window)
        case .resizeThenMove:
            try setSize(frame.size, of: window)
            try setPosition(frame.origin, of: window)
        }
    }

    private func setSize(_ size: CGSize, of window: AXUIElement) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            throw AccessibilityFailure("Could not encode window frame.")
        }
        try chrome.set(window, attribute: kAXSizeAttribute, value: value)
    }

    private func setPosition(_ origin: CGPoint, of window: AXUIElement) throws {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else {
            throw AccessibilityFailure("Could not encode window frame.")
        }
        try chrome.set(window, attribute: kAXPositionAttribute, value: value)
    }

    private func observeNormalFrame(_ window: AXUIElement) throws -> NormalFrameObservation {
        guard try chrome.windows().contains(where: { CFEqual($0, window) }) else {
            return NormalFrameObservation(frame: nil, isFullScreen: nil, isListed: false)
        }
        do {
            guard let isFullScreen = try chrome.attribute(window, "AXFullScreen") as? Bool else {
                throw AccessibilityFailure("Chrome's full-screen state is unavailable.")
            }
            return NormalFrameObservation(frame: try rect(window), isFullScreen: isFullScreen, isListed: true)
        } catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement {
            return NormalFrameObservation(frame: nil, isFullScreen: nil, isListed: true)
        }
    }

    private func matchesFrame(_ actual: CGRect, _ expected: CGRect) -> Bool {
        NormalFrameObservation.matchesFrame(actual, expected)
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
            try self.focusOwnedWindowForSubmission()
            try self.chrome.set(addressField, attribute: kAXFocusedAttribute, value: kCFBooleanTrue)
            let entry = ChromeAddressEntry(
                chrome: self.chrome,
                addressField: addressField,
                expected: self.website.absoluteString,
                validateRecipient: {
                    // Each check names its own failure so an interrupted
                    // submission reports what actually moved.
                    guard try self.chrome.windows().contains(where: { CFEqual($0, window) }) else {
                        throw AccessibilityFailure("The setup window closed; submission stopped.")
                    }
                    let display = try self.target.validate()
                    let windowFrame = try self.rect(window)
                    guard display.bounds.contains(windowFrame) else {
                        throw AccessibilityFailure("The setup window moved off \(self.monitor.name) to \(NSStringFromRect(windowFrame)); submission stopped.")
                    }
                    guard let focusedWindow = try self.chrome.attribute(self.chrome.application, kAXFocusedWindowAttribute),
                          CFEqual(focusedWindow, window) else {
                        throw AccessibilityFailure("The setup window is no longer Chrome's focused window; submission stopped.")
                    }
                    guard let focus = try self.chrome.attribute(self.chrome.application, kAXFocusedUIElementAttribute),
                          CFEqual(focus, addressField) else {
                        throw AccessibilityFailure("Keyboard focus left the setup window's address field; submission stopped.")
                    }
                    let foreground = NSWorkspace.shared.frontmostApplication
                    guard try self.chrome.attribute(self.chrome.application, kAXFrontmostAttribute) as? Bool == true,
                          foreground?.processIdentifier == self.chrome.pid else {
                        throw AccessibilityFailure("Chrome is no longer the foreground app (foreground: \(foreground?.localizedName ?? "unknown")); submission stopped.")
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
        let splitTabs = window.nodes.filter {
            $0.role == kAXRadioButtonRole && $0.domClassList.contains(ChromeViewClass.tab) && $0.value == "1"
        }
        let arrangeButtons = window.nodes.filter {
            $0.role == kAXPopUpButtonRole && $0.domClassList.contains(ChromeViewClass.splitButton)
        }
        let handles = window.nodes.filter { $0.domClassList.contains(ChromeViewClass.splitResizeHandle) }
        return splitTabs.count == 2 && arrangeButtons.count == 1 && handles.count == 1
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
        catch {
            log(["event": "setup-step-failed", "step": name, "error": String(describing: error)])
            throw SetupStepFailure(step: name, cause: error)
        }
    }
}
