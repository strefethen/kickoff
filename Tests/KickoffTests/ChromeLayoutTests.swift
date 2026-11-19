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

    private final class FakeChrome: ChromeLayoutAccessing, ChromeWindowScripting {
        enum FullScreenRead {
            case value(Bool?)
            case failure(AccessibilityFailure)
        }

        let pid: pid_t = 42
        let application = AXUIElementCreateApplication(42)
        let window = AXUIElementCreateApplication(101)
        let replacementWindow = AXUIElementCreateApplication(102)
        let fullScreenButton = AXUIElementCreateApplication(103)
        let closeButton = AXUIElementCreateApplication(106)
        let leftPage = AXUIElementCreateApplication(104)
        let rightPage = AXUIElementCreateApplication(105)
        let menuBar = AXUIElementCreateApplication(201)
        let appleMenuItem = AXUIElementCreateApplication(205)
        let chromeMenuItem = AXUIElementCreateApplication(206)
        let incognitoMenuItem = AXUIElementCreateApplication(207)
        let fileMenuItem = AXUIElementCreateApplication(202)
        let fileMenu = AXUIElementCreateApplication(203)
        let newWindowMenuItem = AXUIElementCreateApplication(204)
        var windowReads: [[AXUIElement]] = []
        var transientWindowFailures = 0
        var fullScreenReads: [FullScreenRead] = [.value(false)]
        var frameReads: [CGRect] = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        var actionEnabled = true
        var actionAdvertised = true
        var inspectedNodes: [AccessibilityNode] = []
        var inspectFailures: [AccessibilityFailure] = []
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
        var onPerform: ((String) -> Void)?
        private(set) var presses = 0
        private(set) var performedActions: [String] = []
        private(set) var setAttributes: [String] = []
        private(set) var setSizes: [CGSize] = []
        private var currentFrame = CGRect.zero
        var scriptFailures: [ChromeScriptingFailure] = []
        var replacementFrame: CGRect?
        private(set) var requestedFrames: [CGRect] = []
        private(set) var closedScriptIDs: [String] = []

        func makeWindow(bounds: CGRect) throws -> String {
            requestedFrames.append(bounds)
            if !scriptFailures.isEmpty { throw scriptFailures.removeFirst() }
            return "7001"
        }

        var closeFailure: Error?

        func closeWindow(id: String) throws {
            closedScriptIDs.append(id)
            if let closeFailure { throw closeFailure }
        }

        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            if CFEqual(element, application), name == kAXMenuBarAttribute { return menuBar }
            if CFEqual(element, application), name == kAXMainWindowAttribute { return mainWindow }
            if CFEqual(element, application), name == kAXFocusedWindowAttribute { return focusedWindow }
            if CFEqual(element, menuBar), name == kAXChildrenAttribute {
                return [appleMenuItem, chromeMenuItem, fileMenuItem] as CFArray
            }
            if CFEqual(element, fileMenuItem), name == kAXChildrenAttribute { return [fileMenu] as CFArray }
            if CFEqual(element, fileMenu), name == kAXChildrenAttribute {
                return [incognitoMenuItem, newWindowMenuItem] as CFArray
            }
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
                if name == kAXCloseButtonAttribute { return closeButton }
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
            if CFEqual(element, replacementWindow), let replacementFrame {
                if name == kAXPositionAttribute {
                    var point = replacementFrame.origin
                    return AXValueCreate(.cgPoint, &point)
                }
                if name == kAXSizeAttribute {
                    var size = replacementFrame.size
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
                if name == kAXTitleAttribute { return "Archivo" }
            }
            if CFEqual(element, fileMenu), name == kAXRoleAttribute { return kAXMenuRole }
            if CFEqual(element, newWindowMenuItem) || CFEqual(element, incognitoMenuItem) {
                if name == kAXRoleAttribute { return kAXMenuItemRole }
                if name == kAXTitleAttribute { return CFEqual(element, newWindowMenuItem) ? "Nueva ventana" : "Nueva ventana de incógnito" }
                if name == "AXIdentifier" { return "commandDispatch:" }
                if name == kAXMenuItemCmdCharAttribute { return "N" }
                if name == kAXMenuItemCmdModifiersAttribute { return CFEqual(element, newWindowMenuItem) ? "0" : "1" }
            }
            return ""
        }

        func windows() throws -> [AXUIElement] {
            if transientWindowFailures > 0 {
                transientWindowFailures -= 1
                throw AccessibilityFailure("Chrome is still starting", axError: .cannotComplete)
            }
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
            if !inspectFailures.isEmpty { throw inspectFailures.removeFirst() }
            return inspectedNodes
        }

        func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws {
            setAttributes.append(attribute)
            var size = CGSize.zero
            if attribute == kAXSizeAttribute, AXValueGetValue(value as! AXValue, .cgSize, &size) {
                setSizes.append(size)
            }
        }

        func advertisedActions(_ element: AXUIElement) throws -> [String] {
            if CFEqual(element, window) { return raiseAdvertised ? [kAXPressAction, kAXRaiseAction] : [kAXPressAction] }
            return actionAdvertised ? [kAXPressAction] : []
        }

        func performOnce(_ action: String, on element: AXUIElement) -> AXError {
            performedActions.append(action)
            onPerform?(action)
            if action == kAXPressAction { presses += 1 }
            return action == kAXRaiseAction ? raiseResult : .success
        }

        func resetWindowReads() { windowReadCount = 0 }
        func resetFrameReads() { frameReadCount = 0 }

        private func repeated<T>(_ values: [T], at index: Int) -> T {
            values[min(index, values.count - 1)]
        }
    }

    private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testWindowIsRequestedAtTargetFrameAndPairedWithoutMenuOrSleep() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.requestedFrames, [expected])
        XCTAssertEqual(chrome.presses, 0)
        XCTAssertEqual(chrome.closedScriptIDs, [])
        XCTAssertEqual(clock.sleeps, [])
    }

    func testTallerInheritedWindowShrinksBeforeMovingOntoShorterTarget() throws {
        let chrome = FakeChrome()
        let inherited = CGRect(x: 2560, y: 167, width: 1673, height: 1128)
        let expected = CGRect(x: 24, y: 49, width: 1872, height: 1007)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected, inherited, expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.setAttributes, [kAXSizeAttribute, kAXPositionAttribute, kAXSizeAttribute])
        XCTAssertEqual(chrome.setSizes, [CGSize(width: 1673, height: 1007), expected.size])
        XCTAssertEqual(clock.sleeps, [])
    }

    func testChromeNotReadyForScriptingIsRetriedWithinDeadline() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.scriptFailures = [.from(errorNumber: -600, message: "not running"), .from(errorNumber: -609, message: "connection invalid")]
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.requestedFrames, [expected, expected, expected])
        XCTAssertEqual(clock.sleeps, [0.2, 0.2])
    }

    func testDeniedAutomationStopsWithoutRetryOrWindow() throws {
        let chrome = FakeChrome()
        chrome.scriptFailures = [.from(errorNumber: -1743, message: "Not authorized")]
        chrome.windowReads = [[]]
        let (layout, clock) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.prepare(frame: CGRect(x: 0, y: 25, width: 1920, height: 527))) { error in
            XCTAssertEqual((error as? ChromeScriptingFailure)?.kind, .notPermitted)
            XCTAssertTrue(String(describing: error).contains("Privacy & Security > Automation"))
        }
        XCTAssertEqual(chrome.requestedFrames.count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testTimedOutWindowRequestIsNeverRepeated() throws {
        let chrome = FakeChrome()
        chrome.scriptFailures = [.from(errorNumber: -1712, message: "timed out")]
        chrome.windowReads = [[]]
        let (layout, _) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.prepare(frame: CGRect(x: 0, y: 25, width: 1920, height: 527)))
        XCTAssertEqual(chrome.requestedFrames.count, 1)
    }

    func testRestoredWindowElsewhereIsNeverPairedAndRequestedWindowIsClosedOnTimeout() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [CGRect(x: 2600, y: 100, width: 1200, height: 900)]
        let (layout, _) = try makeLayout(chrome: chrome, timeout: 1)

        XCTAssertThrowsError(try layout.prepare(frame: expected)) { error in
            XCTAssertTrue(String(describing: error).hasPrefix("Chrome did not open the requested window at {{0, 25}, {1920, 527}}"))
        }
        XCTAssertEqual(chrome.closedScriptIDs, ["7001"])
        XCTAssertFalse(try layout.closeOwnedWindow())
        XCTAssertEqual(chrome.setAttributes, [])
    }

    func testAutomationDenialSurvivesStepWrappingAndIsNotRetryable() throws {
        let chrome = FakeChrome()
        chrome.scriptFailures = [.from(errorNumber: -1743, message: "denied")]
        chrome.windowReads = [[]]
        let (layout, _) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.setupSingleWindow()) { error in
            XCTAssertTrue(error is SetupStepFailure)
            XCTAssertEqual((SetupStepFailure.rootCause(of: error) as? ChromeScriptingFailure)?.kind, .notPermitted)
            XCTAssertFalse(ChromeSetup.isRetryable(error))
        }
    }

    func testRequestedWindowThatCannotBeClosedIsReportedAsLeftOpen() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [CGRect(x: 2600, y: 100, width: 1200, height: 900)]
        chrome.closeFailure = ChromeScriptingFailure.from(errorNumber: -1728, message: "no such window")
        let (layout, _) = try makeLayout(chrome: chrome, timeout: 1)

        XCTAssertThrowsError(try layout.prepare(frame: expected)) { error in
            XCTAssertTrue(error is ChromeWindowLeftOpen)
        }
    }

    func testTwoNewWindowsAtSetupFrameAreNeverGuessedBetween() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window, chrome.replacementWindow]]
        chrome.frameReads = [expected]
        chrome.replacementFrame = expected
        let (layout, _) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.prepare(frame: expected)) { error in
            XCTAssertTrue(String(describing: error).hasPrefix("Several new Chrome windows appeared"))
            XCTAssertTrue(String(describing: error).hasSuffix("Kickoff closed the window it requested."))
        }
        XCTAssertEqual(chrome.closedScriptIDs, ["7001"])
    }

    func testNewWindowRetriesBrieflyWhenChromeIsStillBusy() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.transientWindowFailures = 2
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(clock.sleeps, [0.1, 0.1])
        XCTAssertEqual(chrome.requestedFrames, [expected])
    }

    func testBlankNewTabDoesNotNeedPageURLBeforeNavigation() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = []
        let (layout, clock) = try makeLayout(chrome: chrome)

        let window = try layout.prepare(frame: expected)

        XCTAssertTrue(window.nodes.isEmpty)
        XCTAssertEqual(chrome.requestedFrames, [expected])
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
        let inherited = CGRect(x: 0, y: 0, width: 800, height: 400)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected, inherited, bounds.insetBy(dx: 20, dy: 20), expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.windowReadCount, 6)
        XCTAssertEqual(chrome.setAttributes, [kAXPositionAttribute, kAXSizeAttribute])
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testSizeWriteThatSnapsWindowBackToOldDisplayIsReappliedUntilItHolds() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let inherited = CGRect(x: 2582, y: 47, width: 1370, height: 1007)
        let snappedBack = CGRect(x: 2582, y: 47, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected, inherited, snappedBack, snappedBack, expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.setAttributes, [
            kAXPositionAttribute, kAXSizeAttribute,
            kAXPositionAttribute, kAXSizeAttribute,
        ])
        XCTAssertEqual(chrome.setSizes, [expected.size, expected.size])
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testAnimatingFrameIsAwaitedWithoutRewriting() throws {
        let chrome = FakeChrome()
        let initial = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let lower = CGRect(x: 0, y: 507, width: 1920, height: 573)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [initial]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)
        try layout.prepare(frame: initial)
        chrome.frameReads = [
            initial,
            CGRect(x: 0, y: 128, width: 1920, height: 952),
            CGRect(x: 0, y: 290, width: 1920, height: 790),
            CGRect(x: 0, y: 495, width: 1920, height: 585),
            lower,
        ]
        chrome.resetFrameReads()
        let writesBefore = chrome.setAttributes.count

        try layout.placeWindow(frame: lower)

        XCTAssertEqual(Array(chrome.setAttributes.dropFirst(writesBefore)), [kAXSizeAttribute, kAXPositionAttribute])
        XCTAssertEqual(clock.sleeps, [0.2, 0.2, 0.2])
    }

    func testFramePlacementFailureNamesWhereChromeLeftTheWindow() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let stuck = CGRect(x: 0, y: 47, width: 1370, height: 1007)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected, stuck]
        let (layout, _) = try makeLayout(chrome: chrome, timeout: 1)

        XCTAssertThrowsError(try layout.prepare(frame: expected)) { error in
            XCTAssertEqual(
                String(describing: error),
                "Chrome would not keep the setup window at {{0, 25}, {1920, 1055}} on Test Display; after 5 attempts it was at {{0, 47}, {1370, 1007}}."
            )
        }
    }

    func testCloseOwnedWindowPressesCloseAndWaitsUntilChromeDropsIt() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, clock) = try makeLayout(chrome: chrome)
        try layout.prepare(frame: expected)
        chrome.windowReads = [[chrome.window], [chrome.window], []]
        chrome.resetWindowReads()

        XCTAssertTrue(try layout.closeOwnedWindow())

        XCTAssertEqual(chrome.performedActions.last, kAXPressAction)
        XCTAssertEqual(clock.sleeps, [0.2])
        XCTAssertFalse(try layout.closeOwnedWindow())
    }

    func testCloseReportsOwnedWindowThatChromeStopsListing() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, _) = try makeLayout(chrome: chrome)
        try layout.prepare(frame: expected)
        chrome.windowReads = [[]]
        chrome.resetWindowReads()

        XCTAssertThrowsError(try layout.closeOwnedWindow()) { error in
            XCTAssertTrue(String(describing: error).contains("could not confirm it closed"))
        }
        XCTAssertEqual(chrome.presses, 0)
    }

    func testCloseWaitsForBrieflyUnlistedOwnedWindowThenClosesIt() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        let (layout, _) = try makeLayout(chrome: chrome)
        try layout.prepare(frame: expected)
        chrome.windowReads = [[], [chrome.window], []]
        chrome.resetWindowReads()

        XCTAssertTrue(try layout.closeOwnedWindow())
    }

    func testUnreadableFullScreenStateFailsPlacementImmediately() throws {
        let chrome = FakeChrome()
        chrome.windowReads = [[], [chrome.window]]
        chrome.fullScreenReads = [.value(nil)]
        chrome.frameReads = [CGRect(x: 0, y: 25, width: 1920, height: 527)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        XCTAssertThrowsError(try layout.prepare(frame: CGRect(x: 0, y: 25, width: 1920, height: 527))) { error in
            XCTAssertEqual(String(describing: error), "Chrome's full-screen state is unavailable.")
        }
        XCTAssertEqual(clock.sleeps, [])
    }

    func testPlacedWindowSnapshotRetriesPageElementInvalidatedDuringRead() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 527)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.window)]
        chrome.inspectFailures = [AccessibilityFailure("Reading AXURL failed: AX error -25202.", axError: .invalidUIElement)]
        let (layout, clock) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)

        XCTAssertEqual(chrome.inspectCount, 2)
        XCTAssertEqual(clock.sleeps, [0.2])
    }

    func testProcessLivenessComesFromTheKernel() {
        XCTAssertTrue(ChromeAccessibilityClient.processIsAlive(getpid()))
        XCTAssertFalse(ChromeAccessibilityClient.processIsAlive(99_999_999))
    }

    func testCloseWithoutOwnedWindowNeverTouchesChrome() throws {
        let chrome = FakeChrome()
        let (layout, _) = try makeLayout(chrome: chrome)

        XCTAssertFalse(try layout.closeOwnedWindow())
        XCTAssertEqual(chrome.performedActions, [])
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
        chrome.inspectedNodes = splitNodes(chrome: chrome).filter { !$0.domClassList.contains(ChromeViewClass.splitResizeHandle) }
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

    func testSetupWindowAlreadyFocusedIsNotRaisedBeforeSubmission() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.leftPage)]
        chrome.mainWindow = chrome.window
        chrome.focusedWindow = chrome.window
        let (layout, _) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)
        try layout.focusOwnedWindowForSubmission()

        XCTAssertFalse(chrome.performedActions.contains(kAXRaiseAction))
    }

    func testSetupWindowThatLostFocusIsRaisedBeforeSubmission() throws {
        let chrome = FakeChrome()
        let expected = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        chrome.windowReads = [[], [chrome.window]]
        chrome.frameReads = [expected]
        chrome.inspectedNodes = [pageNode(chrome.leftPage)]
        chrome.mainWindow = chrome.replacementWindow
        chrome.focusedWindow = chrome.replacementWindow
        chrome.onPerform = { action in
            guard action == kAXRaiseAction else { return }
            chrome.mainWindow = chrome.window
            chrome.focusedWindow = chrome.window
        }
        let (layout, _) = try makeLayout(chrome: chrome)

        try layout.prepare(frame: expected)
        try layout.focusOwnedWindowForSubmission()

        XCTAssertEqual(chrome.performedActions.filter { $0 == kAXRaiseAction }, [kAXRaiseAction])
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
            sleep: clock.sleep,
            scripting: chrome
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
        timeout: TimeInterval = 8,
        bounds: CGRect? = nil
    ) throws -> (ChromeLayout, FakeClock) {
        let monitor = makeMonitor(bounds: bounds ?? self.bounds)
        let clock = FakeClock()
        let layout = try ChromeLayout(
            target: MonitorTarget(monitor: monitor, discover: { [monitor] }),
            website: .approvedDefault,
            chrome: chrome,
            now: { clock.current },
            sleep: clock.sleep,
            windowStateTimeout: timeout,
            scripting: chrome
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
            node(chrome.window, role: kAXRadioButtonRole, description: "Juego - Vista izquierda", value: "1", classes: [ChromeViewClass.tab]),
            node(chrome.replacementWindow, role: kAXRadioButtonRole, description: "Juego - Vista derecha", value: "1", classes: [ChromeViewClass.tab]),
            node(chrome.window, role: kAXPopUpButtonRole, classes: [ChromeViewClass.splitButton]),
            node(chrome.window, role: kAXSliderRole, description: "Controlador de cambio de tamaño", classes: [ChromeViewClass.splitResizeHandle]),
        ]
    }

    private func pageNode(_ element: AXUIElement) -> AccessibilityNode {
        node(element, role: "AXWebArea", url: "https://www.hulu.com/", depth: 1)
    }

    private func node(
        _ element: AXUIElement,
        role: String,
        description: String = "",
        value: String = "",
        url: String? = nil,
        depth: Int = 2,
        classes: [String] = []
    ) -> AccessibilityNode {
        AccessibilityNode(
            element: element,
            role: role,
            title: "",
            nodeDescription: description,
            value: value,
            valueDescription: "",
            url: url,
            domIdentifier: "",
            hidden: false,
            depth: depth,
            domClassList: classes
        )
    }
}
