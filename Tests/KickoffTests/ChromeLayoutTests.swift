import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import Kickoff

final class ChromeLayoutTests: XCTestCase {
    private final class FakeClock {
        var current = Date(timeIntervalSinceReferenceDate: 0)
        private(set) var sleeps: [TimeInterval] = []

        func sleep(_ interval: TimeInterval) {
            sleeps.append(interval)
            current.addTimeInterval(interval)
        }
    }

    private final class FakeChrome: ChromeLayoutAccessing {
        enum FullScreenRead {
            case value(Bool?)
            case failure(AccessibilityFailure)
        }

        let pid: pid_t = 42
        let application = AXUIElementCreateApplication(42)
        let window = AXUIElementCreateApplication(101)
        let replacementWindow = AXUIElementCreateApplication(102)
        let fullScreenButton = AXUIElementCreateApplication(103)
        let leftPage = AXUIElementCreateApplication(104)
        let rightPage = AXUIElementCreateApplication(105)
        let menuBar = AXUIElementCreateApplication(201)
        let fileMenuItem = AXUIElementCreateApplication(202)
        let fileMenu = AXUIElementCreateApplication(203)
        let newWindowMenuItem = AXUIElementCreateApplication(204)
        var windowReads: [[AXUIElement]] = []
        var fullScreenReads: [FullScreenRead] = [.value(false)]
        var frameReads: [CGRect] = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        var actionEnabled = true
        var actionAdvertised = true
        var inspectedNodes: [AccessibilityNode] = []
        var leftPageFrame = CGRect(x: 0, y: 87, width: 960, height: 993)
        var rightPageFrame = CGRect(x: 960, y: 87, width: 960, height: 993)
        var mainWindow: AXUIElement?
        var focusedWindow: AXUIElement?
        var raiseAdvertised = true
        var raiseResult: AXError = .success
        private(set) var windowReadCount = 0
        private(set) var fullScreenReadCount = 0
        private(set) var frameReadCount = 0
        private(set) var inspectCount = 0
        var onInspect: ((Int) -> Void)?
        private(set) var presses = 0
        private(set) var performedActions: [String] = []
        private(set) var setAttributes: [String] = []
        private var currentFrame = CGRect.zero

        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            if CFEqual(element, application), name == kAXMenuBarAttribute { return menuBar }
            if CFEqual(element, application), name == kAXMainWindowAttribute { return mainWindow }
            if CFEqual(element, application), name == kAXFocusedWindowAttribute { return focusedWindow }
            if CFEqual(element, menuBar), name == kAXChildrenAttribute { return [fileMenuItem] as CFArray }
            if CFEqual(element, fileMenuItem), name == kAXChildrenAttribute { return [fileMenu] as CFArray }
            if CFEqual(element, fileMenu), name == kAXChildrenAttribute { return [newWindowMenuItem] as CFArray }
            if CFEqual(element, window) {
                if name == "AXFullScreen" {
                    let read = repeated(fullScreenReads, at: fullScreenReadCount)
                    fullScreenReadCount += 1
                    switch read {
                    case let .value(value): return value.map { $0 as CFBoolean }
                    case let .failure(failure): throw failure
                    }
                }
                if name == kAXFullScreenButtonAttribute { return fullScreenButton }
                if name == kAXPositionAttribute {
                    currentFrame = repeated(frameReads, at: frameReadCount)
                    frameReadCount += 1
                    var point = currentFrame.origin
                    return AXValueCreate(.cgPoint, &point)
                }
                if name == kAXSizeAttribute {
                    var size = currentFrame.size
                    return AXValueCreate(.cgSize, &size)
                }
            }
            if CFEqual(element, leftPage) || CFEqual(element, rightPage) {
                let frame = CFEqual(element, leftPage) ? leftPageFrame : rightPageFrame
                if name == kAXPositionAttribute {
                    var point = frame.origin
                    return AXValueCreate(.cgPoint, &point)
                }
                if name == kAXSizeAttribute {
                    var size = frame.size
                    return AXValueCreate(.cgSize, &size)
                }
            }
            if (CFEqual(element, fullScreenButton) || CFEqual(element, newWindowMenuItem)),
               name == kAXEnabledAttribute {
                return actionEnabled as CFBoolean
            }
            return nil
        }

        func text(_ element: AXUIElement, _ name: String) throws -> String {
            if CFEqual(element, fileMenuItem) {
                if name == kAXRoleAttribute { return kAXMenuBarItemRole }
                if name == kAXTitleAttribute { return "File" }
            }
            if CFEqual(element, fileMenu), name == kAXRoleAttribute { return kAXMenuRole }
            if CFEqual(element, newWindowMenuItem) {
                if name == kAXRoleAttribute { return kAXMenuItemRole }
                if name == kAXTitleAttribute { return "New Window" }
            }
            return ""
        }

        func windows() throws -> [AXUIElement] {
            let windows = repeated(windowReads.isEmpty ? [[window]] : windowReads, at: windowReadCount)
            windowReadCount += 1
            return windows
        }

        func isMinimized(_ window: AXUIElement) throws -> Bool { false }

        func inspect(
            _ root: AXUIElement,
            maximumNodes: Int,
            maximumDepth: Int,
            timeout: TimeInterval,
            stopDescending: (AccessibilityNode) -> Bool
        ) throws -> [AccessibilityNode] {
            inspectCount += 1
            onInspect?(inspectCount)
            return inspectedNodes
        }

        func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws {
            setAttributes.append(attribute)
        }

        func advertisedActions(_ element: AXUIElement) throws -> [String] {
            if CFEqual(element, window) { return raiseAdvertised ? [kAXPressAction, kAXRaiseAction] : [kAXPressAction] }
            return actionAdvertised ? [kAXPressAction] : []
        }

        func performOnce(_ action: String, on element: AXUIElement) -> AXError {
            performedActions.append(action)
            if action == kAXPressAction { presses += 1 }
            return action == kAXRaiseAction ? raiseResult : .success
        }

        private func repeated<T>(_ values: [T], at index: Int) -> T {
            values[min(index, values.count - 1)]
        }
    }

    private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testNewWindowMovesToTargetBeforeExpandingAndCompletesWithoutSleepWhenReady() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.setAttributes, [kAXPositionAttribute, kAXSizeAttribute])
        XCTAssertEqual(clock.sleeps, [])
    }

    func testExistingOwnedWindowShrinksBeforeMovingToLowerRow() throws {
        let chrome = FakeChrome()
        let initial = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let lower = CGRect(x: 0, y: 552, width: 1920, height: 528)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [initial]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)
        try layout.prepare(frame: initial)

        chrome.frameReads = [lower]
        try layout.placeWindow(frame: lower)

        XCTAssertEqual(chrome.setAttributes, [
            kAXPositionAttribute, kAXSizeAttribute,
            kAXSizeAttribute, kAXPositionAttribute,
        ])
        XCTAssertEqual(clock.sleeps, [])
    }

    func testNormalFramePollsSameOwnedWindowUntilGeometryMatches() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [bounds.insetBy(dx: 20, dy: 20), expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.windowReadCount, 5)
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testNormalSplitVerificationChecksFrameModeURLsAndSplitUI() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)
        chrome.inspectedNodes = splitNodes(chrome: chrome)
        try layout.verifySplitWindow(frame: expected)

        XCTAssertEqual(chrome.inspectCount, 2)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testNormalSplitVerificationTimesOutWithoutSplitUI() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome, timeout: 0.4)

        try layout.prepare(frame: expected)
        chrome.inspectedNodes = splitNodes(chrome: chrome).filter { !$0.nodeDescription.hasPrefix("Split View Resize Handle") }
        XCTAssertThrowsError(try layout.verifySplitWindow(frame: expected)) { error in
            XCTAssertTrue(String(describing: error).contains("normal split view"))
        }
        XCTAssertEqual(clock.sleeps, [0.2, 0.2])
    }

    func testMeasuredBrowserInsetsComeFromBothOwnedSplitViewports() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.leftPage)]
        chrome.leftPageFrame = CGRect(x: 0, y: 112, width: 960, height: 968)
        chrome.rightPageFrame = CGRect(x: 960, y: 112, width: 960, height: 968)
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)
        chrome.inspectedNodes = splitNodes(chrome: chrome)
        let insets = try layout.measuredBrowserInsets()

        XCTAssertEqual(insets, ChromeBrowserInsets(top: 87, bottom: 0))
        XCTAssertEqual(clock.sleeps, [])
    }

    func testMeasuredBrowserInsetsWaitForViewportResizeAfterOuterFrameChanges() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 753)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.leftPage)]
        chrome.leftPageFrame = CGRect(x: 13, y: 116, width: 937, height: 1200)
        chrome.rightPageFrame = CGRect(x: 970, y: 116, width: 937, height: 1200)
        let (layout, clock) = try makeLayout(chrome: chrome)
        try layout.prepare(frame: expected)
        chrome.inspectedNodes = splitNodes(chrome: chrome)
        chrome.onInspect = { [weak chrome] count in
            if count >= 3 {
                chrome?.leftPageFrame = CGRect(x: 13, y: 116, width: 937, height: 649)
                chrome?.rightPageFrame = CGRect(x: 970, y: 116, width: 937, height: 649)
            }
        }

        XCTAssertEqual(try layout.measuredBrowserInsets(), ChromeBrowserInsets(top: 91, bottom: 13))
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testMeasuredBrowserInsetsRejectMismatchedViewportHeights() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.leftPage)]
        chrome.leftPageFrame = CGRect(x: 0, y: 112, width: 960, height: 968)
        chrome.rightPageFrame = CGRect(x: 960, y: 114, width: 960, height: 966)
        let (layout, _) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)
        chrome.inspectedNodes = splitNodes(chrome: chrome)
        XCTAssertThrowsError(try layout.measuredBrowserInsets()) { error in
            XCTAssertTrue(String(describing: error).contains("did not settle into one vertical frame"))
        }
    }

    func testRaiseOwnedWindowActsOnceAndCompletesWithoutSleepWhenMainAndFocused() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.leftPage)]
        chrome.mainWindow = chrome.window
        chrome.focusedWindow = chrome.window
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)
        try layout.raiseWindow()

        XCTAssertEqual(chrome.performedActions.filter { $0 == kAXRaiseAction }, [kAXRaiseAction])
        XCTAssertEqual(clock.sleeps, [])
    }

    func testRaiseRequiresOwnedWindowAndNeverAdoptsExistingWindow() throws {
        let chrome = FakeChrome()
        let (layout, _) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.raiseWindow()) { error in
            XCTAssertTrue(String(describing: error).contains("created by this setup session"))
        }
        XCTAssertFalse(chrome.performedActions.contains(kAXRaiseAction))
    }

    func testTransientWindowListAbsenceWaitsForSameOwnedWindow() throws {
        let chrome = FakeChrome()
        chrome.windowReads = [[chrome.window], [chrome.replacementWindow], [chrome.window]]
        chrome.fullScreenReads = [.value(false), .value(true), .value(true)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.enterFullScreen()

        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.windowReadCount, 3)
        XCTAssertEqual(chrome.fullScreenReadCount, 2)
        XCTAssertEqual(chrome.frameReadCount, 2)
        XCTAssertEqual(chrome.inspectCount, 1)
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testReplacementWindowIsNeverAcceptedAndTimesOut() throws {
        let chrome = FakeChrome()
        chrome.windowReads = [[chrome.window], [chrome.replacementWindow]]
        chrome.fullScreenReads = [.value(false), .value(true)]
        let (layout, clock) = try makeLayout(chrome: chrome, timeout: 0.4)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertEqual(
                error as? AccessibilityFailure,
                AccessibilityFailure("Chrome did not finish the setup step. No action was repeated.")
            )
        }
        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.inspectCount, 1)
        XCTAssertEqual(clock.sleeps, [0.2, 0.2])
    }

    func testClosedOwnedWindowFailsAtBoundedTimeoutWithoutReadingStaleElement() throws {
        let chrome = FakeChrome()
        chrome.windowReads = [[chrome.window], []]
        chrome.fullScreenReads = [.value(false)]
        let (layout, clock) = try makeLayout(chrome: chrome, timeout: 0.4)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertEqual(
                error as? AccessibilityFailure,
                AccessibilityFailure("Chrome did not finish the setup step. No action was repeated.")
            )
        }
        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.fullScreenReadCount, 1)
        XCTAssertEqual(chrome.frameReadCount, 1)
        XCTAssertEqual(clock.sleeps, [0.2, 0.2])
    }

    func testListedOwnedWindowRetriesTransientInvalidElementRead() throws {
        let chrome = FakeChrome()
        let invalid = AccessibilityFailure("transitioning", axError: .invalidUIElement)
        chrome.fullScreenReads = [.value(false), .failure(invalid), .value(true)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.enterFullScreen()

        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.windowReadCount, 3)
        XCTAssertEqual(chrome.fullScreenReadCount, 3)
        XCTAssertEqual(chrome.frameReadCount, 2)
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testAlreadyFullScreenDoesNotPressOrSleep() throws {
        let chrome = FakeChrome()
        chrome.fullScreenReads = [.value(true)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.enterFullScreen()

        XCTAssertEqual(chrome.presses, 0)
        XCTAssertEqual(chrome.windowReadCount, 2)
        XCTAssertEqual(chrome.fullScreenReadCount, 2)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testReadyOnFirstPostpressPollStopsImmediately() throws {
        let chrome = FakeChrome()
        chrome.fullScreenReads = [.value(false), .value(true)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.enterFullScreen()

        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.windowReadCount, 2)
        XCTAssertEqual(chrome.fullScreenReadCount, 2)
        XCTAssertEqual(chrome.frameReadCount, 2)
        XCTAssertEqual(chrome.inspectCount, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testContainedButIncorrectFullScreenFrameNeverCompletes() throws {
        let chrome = FakeChrome()
        chrome.fullScreenReads = [.value(false), .value(true)]
        chrome.frameReads = [bounds, bounds.insetBy(dx: 1, dy: 1)]
        let (layout, clock) = try makeLayout(chrome: chrome, timeout: 0.4)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertTrue(String(describing: error).contains("did not finish"))
        }
        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(clock.sleeps, [0.2, 0.2])
    }

    func testFrameOutsidePinnedMonitorFailsImmediately() throws {
        let chrome = FakeChrome()
        chrome.fullScreenReads = [.value(false), .value(true)]
        chrome.frameReads = [bounds, CGRect(x: 1920, y: 0, width: 1920, height: 1080)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertTrue(String(describing: error).contains("no longer on Test Display"))
        }
        XCTAssertEqual(clock.sleeps, [])
    }

    func testPinnedMonitorChangeFailsBeforePollingWindowState() throws {
        let chrome = FakeChrome()
        chrome.fullScreenReads = [.value(false), .value(true)]
        var validations = 0
        let monitor = makeMonitor(bounds: bounds)
        let changed = makeMonitor(bounds: CGRect(x: 1, y: 0, width: 1920, height: 1080))
        let target = MonitorTarget(monitor: monitor, discover: {
            validations += 1
            return validations < 4 ? [monitor] : [changed]
        })
        let clock = FakeClock()
        let layout = try ChromeLayout(
            target: target,
            website: .approvedDefault,
            chrome: chrome,
            now: { clock.current },
            sleep: clock.sleep
        )

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertTrue(String(describing: error).contains("changed during setup"))
        }
        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.windowReadCount, 1)
        XCTAssertEqual(chrome.fullScreenReadCount, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testMissingPostpressFullScreenStateFailsWithoutRetry() throws {
        let chrome = FakeChrome()
        chrome.fullScreenReads = [.value(false), .value(nil)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertEqual(
                error as? AccessibilityFailure,
                AccessibilityFailure("Chrome's full-screen state is unavailable.")
            )
        }
        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testNontransientAXErrorFailsWithoutRetry() throws {
        let chrome = FakeChrome()
        let failure = AccessibilityFailure("read failed", axError: .cannotComplete)
        chrome.fullScreenReads = [.value(false), .failure(failure)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertEqual(error as? AccessibilityFailure, failure)
        }
        XCTAssertEqual(chrome.presses, 1)
        XCTAssertEqual(chrome.fullScreenReadCount, 2)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testUnavailableActionNeverPressesOrPolls() throws {
        let chrome = FakeChrome()
        chrome.actionAdvertised = false
        let (layout, clock) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.enterFullScreen()) { error in
            XCTAssertTrue(String(describing: error).contains("requested control is not available"))
        }
        XCTAssertEqual(chrome.presses, 0)
        XCTAssertEqual(chrome.windowReadCount, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    private func makeLayout(
        chrome: FakeChrome,
        timeout: TimeInterval = 8
    ) throws -> (ChromeLayout, FakeClock) {
        let monitor = makeMonitor(bounds: bounds)
        let clock = FakeClock()
        let layout = try ChromeLayout(
            target: MonitorTarget(monitor: monitor, discover: { [monitor] }),
            website: .approvedDefault,
            chrome: chrome,
            now: { clock.current },
            sleep: clock.sleep,
            windowStateTimeout: timeout
        )
        return (layout, clock)
    }

    private func makeMonitor(bounds: CGRect) -> Monitor {
        Monitor(
            identifier: "test-display",
            displayID: 7,
            name: "Test Display",
            isPrimary: false,
            bounds: bounds,
            visibleBounds: bounds
        )
    }

    private func splitNodes(chrome: FakeChrome) -> [AccessibilityNode] {
        [
            node(chrome.leftPage, role: "AXWebArea", url: "https://www.hulu.com/", depth: 1),
            node(chrome.rightPage, role: "AXWebArea", url: "https://www.hulu.com/watch", depth: 1),
            node(chrome.window, role: kAXRadioButtonRole, description: "Game - Left view"),
            node(chrome.replacementWindow, role: kAXRadioButtonRole, description: "Game - Right view"),
            node(chrome.window, role: kAXGroupRole, description: "Split View Resize Handle"),
        ]
    }

    private func pageNode(_ element: AXUIElement) -> AccessibilityNode {
        node(element, role: "AXWebArea", url: "https://www.hulu.com/", depth: 1)
    }

    private func node(
        _ element: AXUIElement,
        role: String,
        description: String = "",
        url: String? = nil,
        depth: Int = 2
    ) -> AccessibilityNode {
        AccessibilityNode(
            element: element,
            role: role,
            title: "",
            nodeDescription: description,
            value: "",
            valueDescription: "",
            url: url,
            domIdentifier: "",
            hidden: false,
            depth: depth
        )
    }
}
