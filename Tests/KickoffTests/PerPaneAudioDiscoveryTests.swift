import ApplicationServices
import Foundation
import XCTest
@testable import Kickoff

private final class PaneChrome: ChromeAccessibilityAccessing {
    final class Pane {
        let window: AXUIElement
        var web: AXUIElement
        let root: AXUIElement
        let marker: AXUIElement
        let tab: AXUIElement
        let button: AXUIElement
        var url: String
        let title: String
        var audio: ChromeTabAudioState?
        var hasButton: Bool
        var side: String?
        var x: CGFloat
        var markerPresent = false
        var conflictingAudio = false
        var hasPlayerRoot = true

        init(window: AXUIElement, id: Int32, url: String, title: String,
             audio: ChromeTabAudioState?, side: String?, x: CGFloat) {
            self.window = window
            web = AXUIElementCreateApplication(1_000 + id)
            root = AXUIElementCreateApplication(2_000 + id)
            marker = AXUIElementCreateApplication(3_000 + id)
            tab = AXUIElementCreateApplication(4_000 + id)
            button = AXUIElementCreateApplication(5_000 + id)
            self.url = url
            self.title = title
            self.audio = audio
            hasButton = audio != nil
            self.side = side
            self.x = x
        }
    }

    let pid: pid_t = 77
    let application = AXUIElementCreateApplication(77)
    let windowA = AXUIElementCreateApplication(101)
    let windowB = AXUIElementCreateApplication(102)
    var panes: [Pane] = []
    private(set) var pressedPanes: [Int] = []

    private var windowList: [AXUIElement] {
        [windowA, windowB].filter { window in panes.contains { CFEqual($0.window, window) } }
    }

    private func pane(where matches: (Pane) -> AXUIElement, is element: AXUIElement) -> Pane? {
        panes.first { CFEqual(matches($0), element) }
    }

    private func audioToken(_ pane: Pane, forDescription: Bool) -> String? {
        guard let audio = pane.audio else { return nil }
        let reported: ChromeTabAudioState = (pane.conflictingAudio && forDescription)
            ? (audio == .muted ? .playing : .muted)
            : audio
        return reported == .muted ? "Audio muted" : "Audio playing"
    }

    private func tabTitle(_ pane: Pane) -> String {
        var parts = [pane.title]
        if let side = pane.side { parts.append(side) }
        if let token = audioToken(pane, forDescription: false) { parts.append(token) }
        parts.append("Memory usage - 100 MB")
        return parts.joined(separator: " - ")
    }

    func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        if let pane = pane(where: \.web, is: element) {
            switch name {
            case kAXURLAttribute: return URL(string: pane.url)! as CFURL
            case "AXHidden": return kCFBooleanFalse
            case kAXPositionAttribute:
                var point = CGPoint(x: pane.x, y: 0)
                return AXValueCreate(.cgPoint, &point)
            case kAXSizeAttribute:
                var size = CGSize(width: 500, height: 500)
                return AXValueCreate(.cgSize, &size)
            default: return nil
            }
        }
        if let pane = pane(where: \.tab, is: element) {
            if name == kAXChildrenAttribute { return (pane.hasButton ? [pane.button] : []) as CFArray }
            if name == "AXSelected" { return kCFBooleanTrue }
            return nil
        }
        if let pane = pane(where: \.button, is: element) {
            if name == kAXParentAttribute { return pane.tab }
            if name == kAXEnabledAttribute { return kCFBooleanTrue }
        }
        return nil
    }

    func text(_ element: AXUIElement, _ name: String) throws -> String {
        if let pane = pane(where: \.tab, is: element) {
            switch name {
            case kAXRoleAttribute: return kAXRadioButtonRole
            case kAXTitleAttribute: return tabTitle(pane)
            case kAXDescriptionAttribute: return audioToken(pane, forDescription: true) ?? ""
            default: return ""
            }
        }
        if pane(where: \.button, is: element) != nil {
            if name == kAXRoleAttribute { return kAXButtonRole }
            if name == kAXTitleAttribute { return "Mute tab" }
        }
        if let pane = pane(where: \.marker, is: element) {
            if name == kAXRoleAttribute { return kAXStaticTextRole }
            if name == kAXValueAttribute { return pane.markerPresent ? "Ad" : "" }
        }
        return ""
    }

    func windows() throws -> [AXUIElement] { windowList }
    func isMinimized(_ window: AXUIElement) throws -> Bool { false }

    func inspect(
        _ root: AXUIElement,
        maximumNodes: Int,
        maximumDepth: Int,
        timeout: TimeInterval,
        stopDescending: (AccessibilityNode) -> Bool
    ) throws -> [AccessibilityNode] {
        if windowList.contains(where: { CFEqual($0, root) }) {
            let inWindow = panes.filter { CFEqual($0.window, root) }
            return inWindow.map { node($0.web, role: "AXWebArea", title: $0.title, url: $0.url, depth: 2) } +
                inWindow.map { node($0.tab, role: kAXRadioButtonRole, title: tabTitle($0), description: audioToken($0, forDescription: true) ?? "", depth: 1) }
        }
        if let pane = pane(where: \.web, is: root) {
            return pane.hasPlayerRoot ? [node(pane.root, role: kAXGroupRole, domIdentifier: "__player__")] : []
        }
        if let pane = pane(where: \.root, is: root) {
            return [
                node(pane.root, role: kAXGroupRole, domIdentifier: "__player__"),
                node(pane.marker, role: kAXStaticTextRole, value: pane.markerPresent ? "Ad" : "", depth: 1),
            ]
        }
        return []
    }

    func advertisedActions(_ element: AXUIElement) throws -> [String] { [kAXPressAction] }

    func performOnce(_ action: String, on element: AXUIElement) -> AXError {
        if let index = panes.firstIndex(where: { CFEqual($0.button, element) }) {
            pressedPanes.append(index)
            panes[index].audio = panes[index].audio == .muted ? .playing : .muted
        }
        return .success
    }

    private func node(
        _ element: AXUIElement, role: String, title: String = "", description: String = "",
        value: String = "", url: String? = nil, domIdentifier: String = "", depth: Int = 0
    ) -> AccessibilityNode {
        AccessibilityNode(
            element: element, role: role, title: title, nodeDescription: description,
            value: value, valueDescription: "", url: url, domIdentifier: domIdentifier,
            hidden: false, depth: depth
        )
    }

    static func quad(audible: Set<Int> = [0]) -> PaneChrome {
        let chrome = PaneChrome()
        let windows = [chrome.windowA, chrome.windowA, chrome.windowB, chrome.windowB]
        chrome.panes = (0..<4).map { index in
            Pane(
                window: windows[index], id: Int32(index),
                url: "https://www.hulu.com/watch/\(index)", title: "Hulu | Watch",
                audio: audible.contains(index) ? .playing : nil,
                side: index.isMultiple(of: 2) ? "Left view" : "Right view",
                x: index.isMultiple(of: 2) ? 0 : 500
            )
        }
        return chrome
    }

    static func splitWithUnsupportedPeer(supportedSide: String, audio: ChromeTabAudioState?) -> PaneChrome {
        let chrome = PaneChrome()
        let supportedIsLeft = supportedSide == "Left view"
        chrome.panes = [
            Pane(window: chrome.windowA, id: 0, url: "https://www.hulu.com/watch/only", title: "Hulu | Watch",
                 audio: audio, side: supportedSide, x: supportedIsLeft ? 0 : 500),
            Pane(window: chrome.windowA, id: 1, url: "https://www.example.com/news", title: "News",
                 audio: nil, side: supportedIsLeft ? "Right view" : "Left view", x: supportedIsLeft ? 500 : 0),
        ]
        return chrome
    }

    static func separateWindows(audio: [ChromeTabAudioState?]) -> PaneChrome {
        let chrome = PaneChrome()
        chrome.panes = audio.enumerated().map { index, state in
            Pane(window: index == 0 ? chrome.windowA : chrome.windowB, id: Int32(index),
                 url: "https://www.hulu.com/watch/\(index)", title: "Hulu | Watch",
                 audio: state, side: nil, x: 0)
        }
        return chrome
    }
}

final class PerPaneAudioDiscoveryTests: XCTestCase {
    func testQuadWithOneAudibleAndThreeSilentPanesReportsEveryPane() throws {
        let chrome = PaneChrome.quad()
        let client = ChromePlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()

        XCTAssertEqual(players.count, 4)
        XCTAssertEqual(players[0].audio, .playing)
        XCTAssertEqual(players.filter(\.hasAudioControls).count, 1)
        XCTAssertEqual(Set(players.map(\.identity.token)).count, 4)
        for silent in players.dropFirst() {
            XCTAssertEqual(silent.audio, .noControls(reason: "Chrome is not reporting tab audio state."))
        }
        XCTAssertTrue(chrome.pressedPanes.isEmpty)

        let summaries = try client.discoveryReport()
        XCTAssertEqual(summaries.count, 4)
        XCTAssertEqual(summaries[0]["muted"] as? Bool, false)
        XCTAssertEqual(summaries[0]["tabAudioControls"] as? String, "available")
        XCTAssertTrue(summaries[1]["muted"] is NSNull)
        XCTAssertEqual(summaries[1]["tabAudioControls"] as? String, "unavailable")
        XCTAssertTrue(try XCTUnwrap(summaries[1]["audioDescription"] as? String).contains("No Chrome tab audio controls"))
    }

    func testPaneWithAudioStateButNoButtonIsNotMuteEvidence() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[1].audio = .muted
        chrome.panes[1].hasButton = false
        let players = try ChromePlayerClient(chrome: chrome).discoverPlayers()
        XCTAssertEqual(players[1].audio, .noControls(reason: "Chrome is not exposing a native tab audio button."))
    }

    func testSilentPaneIsNeverPressedEvenWhenMarkedAd() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[1].markerPresent = true
        let client = ChromePlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()
        let expected = players.map(\.identity)

        XCTAssertTrue(players[1].hasAdMarker)
        XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(players[1].identity, expectedPlayers: expected, isCancelled: { false }))
        XCTAssertThrowsError(try client.unmuteIfAdMarkerAbsent(players[1].identity, expectedPlayers: expected, isCancelled: { false }))
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }

    func testSilentPaneWithoutPlayerRootDoesNotHideAudiblePane() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[0].markerPresent = true
        chrome.panes[2].hasPlayerRoot = false
        let client = ChromePlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()

        XCTAssertEqual(players.count, 4)
        XCTAssertTrue(players[0].hasAdMarker)
        XCTAssertFalse(players[2].hasAdMarker)
        guard case let .noControls(reason) = players[2].audio else { return XCTFail("expected no controls") }
        XCTAssertTrue(reason.contains("Player evidence unavailable"))
        XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: players.map(\.identity), isCancelled: { false }), .mutedAndVerified)
        XCTAssertEqual(chrome.pressedPanes, [0])
    }

    func testPaneWithControlsStillFailsWithoutPlayerRoot() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[0].hasPlayerRoot = false
        XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).discoverPlayers()) { error in
            XCTAssertTrue(error is AccessibilityFailure)
        }
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }

    func testPaneThatJustLostControlsIsNotPressedAndKeepsTheOldFailure() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[0].markerPresent = true
        let client = ChromePlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()
        chrome.panes[0].audio = nil
        chrome.panes[0].hasButton = false
        XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: players.map(\.identity), isCancelled: { false })) {
            XCTAssertTrue($0 is ChromeAudioControlsUnavailable)
        }
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }

    func testSplitWithOneSupportedPaneMapsTheCorrectSide() throws {
        for side in ["Left view", "Right view"] {
            let chrome = PaneChrome.splitWithUnsupportedPeer(supportedSide: side, audio: .playing)
            chrome.panes[0].markerPresent = true
            let client = ChromePlayerClient(chrome: chrome)
            let players = try client.discoverPlayers()

            XCTAssertEqual(players.count, 1)
            XCTAssertEqual(players[0].identity.url, "https://www.hulu.com/watch/only")
            XCTAssertEqual(players[0].audio, .playing)
            XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: [players[0].identity], isCancelled: { false }), .mutedAndVerified)
            XCTAssertEqual(chrome.pressedPanes, [0], side)
            XCTAssertEqual(chrome.panes[0].audio, .muted)
            XCTAssertNil(chrome.panes[1].audio)
        }
    }

    func testSplitWithUnsupportedPeerAcceptsPaneWithoutControlsThroughOldPath() throws {
        let chrome = PaneChrome.splitWithUnsupportedPeer(supportedSide: "Right view", audio: nil)
        XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).discoverPlayers()) { error in
            XCTAssertEqual((error as? ChromeAudioControlsUnavailable)?.watchAreas.count, 1)
        }
    }

    func testSplitWithUnsupportedPeerStillRejectsConflictingGeometry() throws {
        let chrome = PaneChrome.splitWithUnsupportedPeer(supportedSide: "Left view", audio: .playing)
        chrome.panes[1].x = 200
        XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).discoverPlayers()) { error in
            XCTAssertTrue(error is AccessibilityFailure)
        }
    }

    func testUnsupportedPeerMovingDuringPassStopsThePress() throws {
        let chrome = PaneChrome.splitWithUnsupportedPeer(supportedSide: "Left view", audio: .playing)
        chrome.panes[0].markerPresent = true
        let client = ChromePlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()
        chrome.panes[1].x = 200
        XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: [players[0].identity], isCancelled: { false }))
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }

    func testAudiblePaneMutesAndRestoresWhilePeersLackControls() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[0].markerPresent = true
        let client = ChromePlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()
        let expected = players.map(\.identity)

        XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: expected, isCancelled: { false }), .mutedAndVerified)
        XCTAssertEqual(chrome.pressedPanes, [0])
        XCTAssertEqual(chrome.panes[0].audio, .muted)

        chrome.panes[0].markerPresent = false
        let later = try client.discoverPlayers()
        XCTAssertEqual(later.map(\.identity), expected)
        XCTAssertEqual(later[0].audio, .muted)
        XCTAssertEqual(try client.unmuteIfAdMarkerAbsent(later[0].identity, expectedPlayers: later.map(\.identity), isCancelled: { false }), .unmutedAndVerified)
        XCTAssertEqual(chrome.pressedPanes, [0, 0])
        XCTAssertEqual(chrome.panes[0].audio, .playing)
        XCTAssertTrue(chrome.panes.dropFirst().allSatisfy { $0.audio == nil })
    }

    func testPeerPaneChangesStillStopThePass() throws {
        for change in 0..<2 {
            let chrome = PaneChrome.quad()
            chrome.panes[0].markerPresent = true
            let client = ChromePlayerClient(chrome: chrome)
            let players = try client.discoverPlayers()
            if change == 0 {
                chrome.panes[3].url = "https://www.hulu.com/watch/changed"
            } else {
                chrome.panes[3].web = AXUIElementCreateApplication(9_999)
            }
            XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: players.map(\.identity), isCancelled: { false }))
            XCTAssertTrue(chrome.pressedPanes.isEmpty)
        }
    }

    func testConflictingPeerAudioStaysTerminal() throws {
        let chrome = PaneChrome.quad()
        chrome.panes[2].audio = .playing
        chrome.panes[2].hasButton = false
        chrome.panes[2].conflictingAudio = true
        XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).discoverPlayers()) { error in
            XCTAssertTrue(error is AccessibilityFailure)
        }
    }

    func testAllPanesWithoutControlsFollowTheUnavailablePath() throws {
        let chrome = PaneChrome.quad(audible: [])
        XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).discoverPlayers()) { error in
            let unavailable = error as? ChromeAudioControlsUnavailable
            XCTAssertEqual(unavailable?.watchAreas.count, 4)
            XCTAssertEqual(unavailable?.description, "Chrome is not reporting tab audio state.")
        }
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }

    func testListenFailsClearlyWhenEitherPlayerLacksControls() throws {
        let chrome = PaneChrome.separateWindows(audio: [.playing, nil])
        XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).listen(to: "https://www.hulu.com/watch/0")) { error in
            XCTAssertTrue(String(describing: error).contains("Listening requires Chrome tab audio controls on both players"))
        }
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }

    func testMonitorMutesAndRestoresAudiblePaneWhilePeersStaySilent() {
        let chrome = PaneChrome.quad()
        chrome.panes[0].markerPresent = true
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 0.01) { ChromePlayerClient(chrome: chrome) }
        let restored = expectation(description: "audible pane restored")
        monitor.onStatusChange = { status in
            if status == .monitoring(players: 1, newlyMuted: 1, newlyUnmuted: 0) {
                queue.async { chrome.panes[0].markerPresent = false }
            }
            if status == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 1) { restored.fulfill() }
            if case let .failed(message) = status { XCTFail(message) }
        }
        monitor.start()
        wait(for: [restored], timeout: 2)
        let drained = expectation(description: "drained")
        monitor.stopAndDrain { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(chrome.pressedPanes, [0, 0])
    }

    func testMonitorWaitsWhenNoPaneHasControls() {
        let chrome = PaneChrome.quad(audible: [])
        chrome.panes[0].markerPresent = true
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) { ChromePlayerClient(chrome: chrome) }
        let waiting = expectation(description: "waiting for audio controls")
        waiting.assertForOverFulfill = false
        monitor.onStatusChange = { status in
            if case .waitingForAudioControls = status { waiting.fulfill() }
            if case .monitoring = status { XCTFail("no pane has controls") }
        }
        monitor.start()
        wait(for: [waiting], timeout: 2)
        let drained = expectation(description: "drained")
        monitor.stopAndDrain { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(chrome.pressedPanes.isEmpty)
    }
}
