import CoreGraphics
import Foundation
import XCTest
@testable import Kickoff

final class ChromeSetupTests: XCTestCase {
    private enum StubError: Error, Equatable {
        case setup
        case verify
    }

    private final class FakeSession: ChromeWindowSettingUp {
        let id: Int
        let events: (String) -> Void
        var setupError: Error?
        var splitError: Error?
        var verifyError: Error?
        var insets = ChromeBrowserInsets(top: 100, bottom: 0)

        init(id: Int, events: @escaping (String) -> Void) {
            self.id = id
            self.events = events
        }

        func setup() throws {
            events("setup:\(id)")
            if let setupError { throw setupError }
        }

        func setupSplitWindow(frame: CGRect) throws {
            events("split:\(id):\(NSStringFromRect(frame))")
            if let splitError { throw splitError }
        }

        func measuredBrowserInsets() throws -> ChromeBrowserInsets {
            events("measure:\(id)")
            return insets
        }

        func placeWindow(frame: CGRect) throws {
            events("place:\(id):\(NSStringFromRect(frame))")
        }

        func raiseWindow() throws {
            events("raise:\(id)")
        }

        func verifySplitWindow(frame: CGRect) throws {
            events("verify:\(id):\(NSStringFromRect(frame))")
            if let verifyError { throw verifyError }
        }
    }

    func testQuadFramesUseMeasuredUnequalBrowserInsetsAndOverlapBottomChrome() throws {
        let visible = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let topInsets = ChromeBrowserInsets(top: 121, bottom: 0)
        let bottomInsets = ChromeBrowserInsets(top: 87, bottom: 0)

        let frames = try ChromeSetup.quadFrames(
            in: visible,
            topInsets: topInsets,
            bottomInsets: bottomInsets
        )

        XCTAssertEqual(frames.top, CGRect(x: 0, y: 25, width: 2560, height: 768))
        XCTAssertEqual(frames.bottom, CGRect(x: 0, y: 706, width: 2560, height: 734))
        XCTAssertEqual(frames.top.maxY, frames.bottom.minY + bottomInsets.top)
        XCTAssertEqual(frames.bottom.maxY, visible.maxY)
    }

    func testQuadFramesGiveOddContentRemainderToBottomViewport() throws {
        let visible = CGRect(x: -1440, y: 20, width: 1440, height: 1000)
        let topInsets = ChromeBrowserInsets(top: 100, bottom: 10)
        let bottomInsets = ChromeBrowserInsets(top: 80, bottom: 9)

        let frames = try ChromeSetup.quadFrames(
            in: visible,
            topInsets: topInsets,
            bottomInsets: bottomInsets
        )

        XCTAssertEqual(frames.top, CGRect(x: -1440, y: 20, width: 1440, height: 550))
        XCTAssertEqual(frames.bottom, CGRect(x: -1440, y: 490, width: 1440, height: 530))
        XCTAssertEqual(frames.top.height - topInsets.top - topInsets.bottom, 440)
        XCTAssertEqual(frames.bottom.height - bottomInsets.top - bottomInsets.bottom, 441)
        XCTAssertEqual(frames.top.maxY, frames.bottom.minY + bottomInsets.top)
    }

    func testSplitModeCreatesOneSessionAndRoutesExistingSetup() throws {
        var events: [String] = []
        let monitor = makeMonitor()
        let target = MonitorTarget(monitor: monitor, discover: { [monitor] })
        let website = try WebsiteURL("https://example.com/watch")
        var capturedMonitors: [Monitor] = []
        var capturedWebsites: [WebsiteURL] = []
        let setup = ChromeSetup(target: target, website: website) { target, website in
            capturedMonitors.append(target.monitor)
            capturedWebsites.append(website)
            return FakeSession(id: capturedMonitors.count, events: { events.append($0) })
        }

        try setup.setup(mode: .split)

        XCTAssertEqual(events, ["setup:1"])
        XCTAssertEqual(capturedMonitors, [monitor])
        XCTAssertEqual(capturedWebsites, [website])
    }

    func testQuadUsesTwoSequentialSessionsThenVerifiesPair() throws {
        var events: [String] = []
        let monitor = makeMonitor(visibleBounds: CGRect(x: 0, y: 25, width: 2560, height: 1415))
        let target = MonitorTarget(monitor: monitor, discover: { [monitor] })
        let website = try WebsiteURL("https://example.com/watch")
        var capturedWebsites: [WebsiteURL] = []
        let setup = ChromeSetup(target: target, website: website) { target, capturedWebsite in
            XCTAssertEqual(target.monitor, monitor)
            capturedWebsites.append(capturedWebsite)
            let id = capturedWebsites.count
            events.append("make:\(id)")
            let session = FakeSession(id: id, events: { events.append($0) })
            session.insets = id == 1
                ? ChromeBrowserInsets(top: 121, bottom: 0)
                : ChromeBrowserInsets(top: 87, bottom: 0)
            return session
        }

        try setup.setup(mode: .quad)

        let frames = try ChromeSetup.quadFrames(
            in: monitor.visibleBounds,
            topInsets: ChromeBrowserInsets(top: 121, bottom: 0),
            bottomInsets: ChromeBrowserInsets(top: 87, bottom: 0)
        )
        XCTAssertEqual(events, [
            "make:1",
            "split:1:\(NSStringFromRect(monitor.visibleBounds))",
            "make:2",
            "split:2:\(NSStringFromRect(monitor.visibleBounds))",
            "measure:1",
            "measure:2",
            "place:1:\(NSStringFromRect(frames.top))",
            "place:2:\(NSStringFromRect(frames.bottom))",
            "verify:1:\(NSStringFromRect(frames.top))",
            "verify:2:\(NSStringFromRect(frames.bottom))",
            "measure:1",
            "measure:2",
            "raise:1",
        ])
        XCTAssertEqual(capturedWebsites, [website, website])
    }

    func testFirstWindowFailureDoesNotCreateAnotherSession() throws {
        var factoryCalls = 0
        let monitor = makeMonitor()
        let target = MonitorTarget(monitor: monitor, discover: { [monitor] })
        let setup = ChromeSetup(target: target, website: .approvedDefault) { _, _ in
            factoryCalls += 1
            let session = FakeSession(id: factoryCalls, events: { _ in })
            session.splitError = StubError.setup
            return session
        }

        XCTAssertThrowsError(try setup.setup(mode: .quad)) { error in
            XCTAssertEqual(error as? StubError, .setup)
        }
        XCTAssertEqual(factoryCalls, 1)
    }

    func testFinalVerificationFailureDoesNotCreateReplacementSession() throws {
        var factoryCalls = 0
        var verifyCalls: [Int] = []
        let monitor = makeMonitor()
        let target = MonitorTarget(monitor: monitor, discover: { [monitor] })
        let setup = ChromeSetup(target: target, website: .approvedDefault) { _, _ in
            factoryCalls += 1
            let id = factoryCalls
            let session = FakeSession(id: id, events: { event in
                if event.hasPrefix("verify:") { verifyCalls.append(id) }
            })
            if factoryCalls == 1 { session.verifyError = StubError.verify }
            return session
        }

        XCTAssertThrowsError(try setup.setup(mode: .quad)) { error in
            XCTAssertEqual(error as? StubError, .verify)
        }
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(verifyCalls, [1])
    }

    private func makeMonitor(
        visibleBounds: CGRect = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    ) -> Monitor {
        Monitor(
            identifier: "test-display",
            displayID: 7,
            name: "Test Display",
            isPrimary: false,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleBounds: visibleBounds
        )
    }
}
