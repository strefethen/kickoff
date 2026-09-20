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
        var windowReads: [[AXUIElement]] = []
        var fullScreenReads: [FullScreenRead] = [.value(false)]
        var frameReads: [CGRect] = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        var actionEnabled = true
        var actionAdvertised = true
        private(set) var windowReadCount = 0
        private(set) var fullScreenReadCount = 0
        private(set) var frameReadCount = 0
        private(set) var inspectCount = 0
        private(set) var presses = 0
        private var currentFrame = CGRect.zero

        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
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
            if CFEqual(element, fullScreenButton), name == kAXEnabledAttribute {
                return actionEnabled as CFBoolean
            }
            return nil
        }

        func text(_ element: AXUIElement, _ name: String) throws -> String { "" }

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
            return []
        }

        func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws {}

        func advertisedActions(_ element: AXUIElement) throws -> [String] {
            actionAdvertised ? [kAXPressAction] : []
        }

        func performOnce(_ action: String, on element: AXUIElement) -> AXError {
            presses += 1
            return .success
        }

        private func repeated<T>(_ values: [T], at index: Int) -> T {
            values[min(index, values.count - 1)]
        }
    }

    private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

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
            fullScreenTimeout: timeout
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
}
