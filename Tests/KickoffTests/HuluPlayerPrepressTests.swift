import ApplicationServices
import Foundation
import XCTest
@testable import Kickoff

final class HuluPlayerPrepressTests: XCTestCase {
    private final class FakeChrome: ChromeAccessibilityAccessing {
        let pid: pid_t = 42
        let application = AXUIElementCreateApplication(42)
        let window1 = AXUIElementCreateApplication(101)
        let window2 = AXUIElementCreateApplication(102)
        let replacementWindow1 = AXUIElementCreateApplication(103)
        let web1 = AXUIElementCreateApplication(201)
        let web2 = AXUIElementCreateApplication(202)
        let replacementWeb1 = AXUIElementCreateApplication(203)
        let root1 = AXUIElementCreateApplication(301)
        let root2 = AXUIElementCreateApplication(302)
        let marker1 = AXUIElementCreateApplication(401)
        let marker2 = AXUIElementCreateApplication(402)
        let tab1 = AXUIElementCreateApplication(501)
        let tab2 = AXUIElementCreateApplication(502)
        let replacementTab1 = AXUIElementCreateApplication(503)
        let button1 = AXUIElementCreateApplication(601)
        let button2 = AXUIElementCreateApplication(602)
        let replacementButton1 = AXUIElementCreateApplication(603)

        var pageCount = 1
        var split = false
        var duplicateURLs = false
        var replaceWindow1 = false
        var replaceWeb1 = false
        var replaceTab1 = false
        var replaceButton1 = false
        var markerPresent = [true, true]
        var audioState = [ChromeTabAudioState.playing, .playing]
        var selected = [true, true]
        var buttonEnabled = true
        var actionAdvertised = true
        var mutationChangesState = true
        var persistentUnknownAudio = false
        var postpressUnknownAudio = false
        var transientConflictReads = 0
        var postpressTransientConflictReads = 0
        var onAdvertisedActions: (() -> Void)?
        var onMarkerValueRead: (() -> Void)?
        var rejectWindowTraversal = false
        var playerScanCount = 0
        var rejectTraversalAfterPlayerScan: Int?
        private(set) var presses = 0

        private var webs: [AXUIElement] { [replaceWeb1 ? replacementWeb1 : web1, web2] }
        private var roots: [AXUIElement] { [root1, root2] }
        private var markers: [AXUIElement] { [marker1, marker2] }
        private var tabs: [AXUIElement] { [replaceTab1 ? replacementTab1 : tab1, tab2] }
        private var buttons: [AXUIElement] { [replaceButton1 ? replacementButton1 : button1, button2] }
        private func index(_ element: AXUIElement, in values: [AXUIElement]) -> Int? {
            values.firstIndex(where: { CFEqual($0, element) })
        }
        private func pageURL(_ index: Int) -> String {
            duplicateURLs ? "https://www.hulu.com/watch/same" : "https://www.hulu.com/watch/\(index + 1)"
        }
        private func window(for index: Int) -> AXUIElement {
            if split || index == 0 { return replaceWindow1 ? replacementWindow1 : window1 }
            return window2
        }

        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            if let index = index(element, in: webs) {
                if name == kAXURLAttribute { return URL(string: pageURL(index))! as CFURL }
                if name == "AXHidden" { return kCFBooleanFalse }
                if name == kAXPositionAttribute {
                    var point = CGPoint(x: index == 0 ? 0 : 500, y: 0)
                    return AXValueCreate(.cgPoint, &point)
                }
                if name == kAXSizeAttribute {
                    var size = CGSize(width: 500, height: 500)
                    return AXValueCreate(.cgSize, &size)
                }
            }
            if let index = index(element, in: tabs) {
                if name == kAXChildrenAttribute { return [buttons[index]] as CFArray }
                if name == "AXSelected" { return selected[index] as CFBoolean }
            }
            if let index = index(element, in: buttons) {
                if name == kAXParentAttribute { return tabs[index] }
                if name == kAXEnabledAttribute { return buttonEnabled as CFBoolean }
            }
            if index(element, in: roots) != nil || index(element, in: markers) != nil, name == "AXHidden" {
                return kCFBooleanFalse
            }
            return nil
        }

        func text(_ element: AXUIElement, _ name: String) throws -> String {
            if let index = index(element, in: tabs) {
                if name == kAXRoleAttribute { return kAXRadioButtonRole }
                if name == kAXTitleAttribute { return tabTitle(index, forDescription: false) }
                if name == kAXDescriptionAttribute { return tabTitle(index, forDescription: true) }
            }
            if index(element, in: buttons) != nil {
                if name == kAXRoleAttribute { return kAXButtonRole }
                if name == kAXTitleAttribute { return "Mute tab" }
            }
            if let index = index(element, in: markers) {
                if name == kAXRoleAttribute { return kAXStaticTextRole }
                if name == kAXValueAttribute {
                    onMarkerValueRead?()
                    onMarkerValueRead = nil
                    return markerPresent[index] ? "Ad" : ""
                }
            }
            return ""
        }

        private func tabTitle(_ index: Int, forDescription: Bool) -> String {
            if persistentUnknownAudio { return forDescription ? "" : "Hulu | Watch - Memory usage - 100 MB" }
            let actual = audioState[index]
            let reported: ChromeTabAudioState
            if forDescription, transientConflictReads > 0 {
                transientConflictReads -= 1
                reported = actual == .muted ? .playing : .muted
            } else {
                reported = actual
            }
            let audio = reported == .muted ? "Audio muted" : "Audio playing"
            let side = split ? (index == 0 ? " - Left view" : " - Right view") : ""
            return forDescription ? audio : "Hulu | Watch\(side) - \(audio) - Memory usage - 100 MB"
        }

        func windows() throws -> [AXUIElement] {
            pageCount == 2 && !split ? [window(for: 0), window2] : [window(for: 0)]
        }
        func isMinimized(_ window: AXUIElement) throws -> Bool { false }

        func inspect(
            _ root: AXUIElement,
            maximumNodes: Int,
            maximumDepth: Int,
            timeout: TimeInterval,
            stopDescending: (AccessibilityNode) -> Bool
        ) throws -> [AccessibilityNode] {
            if CFEqual(root, window(for: 0)) {
                if rejectWindowTraversal { throw AccessibilityFailure("unexpected traversal after final marker") }
                let indices = split ? Array(0..<pageCount) : (pageCount > 0 ? [0] : [])
                return indices.map { node(webs[$0], role: "AXWebArea", title: "Hulu | Watch", url: pageURL($0), depth: 2) } +
                    indices.map { node(tabs[$0], role: kAXRadioButtonRole, title: tabTitle($0, forDescription: false), description: tabTitle($0, forDescription: true), depth: 1) }
            }
            if CFEqual(root, window2), pageCount == 2, !split {
                if rejectWindowTraversal { throw AccessibilityFailure("unexpected traversal after final marker") }
                return [
                    node(web2, role: "AXWebArea", title: "Hulu | Watch", url: pageURL(1), depth: 2),
                    node(tab2, role: kAXRadioButtonRole, title: tabTitle(1, forDescription: false), description: tabTitle(1, forDescription: true), depth: 1),
                ]
            }
            if let index = index(root, in: webs) {
                return [node(roots[index], role: kAXGroupRole, domIdentifier: "__player__")]
            }
            if let index = index(root, in: roots) {
                playerScanCount += 1
                let result = [
                    node(roots[index], role: kAXGroupRole, domIdentifier: "__player__"),
                    node(markers[index], role: kAXStaticTextRole, value: markerPresent[index] ? "Ad" : ""),
                ]
                if rejectTraversalAfterPlayerScan == playerScanCount { rejectWindowTraversal = true }
                return result
            }
            return []
        }

        func advertisedActions(_ element: AXUIElement) throws -> [String] {
            onAdvertisedActions?()
            onAdvertisedActions = nil
            return actionAdvertised ? [kAXPressAction] : []
        }

        func performOnce(_ action: String, on element: AXUIElement) -> AXError {
            presses += 1
            rejectWindowTraversal = false
            if mutationChangesState, let index = index(element, in: buttons) { audioState[index] = audioState[index] == .muted ? .playing : .muted }
            persistentUnknownAudio = postpressUnknownAudio
            transientConflictReads = postpressTransientConflictReads
            return .success
        }

        private func node(
            _ element: AXUIElement,
            role: String,
            title: String = "",
            description: String = "",
            value: String = "",
            url: String? = nil,
            domIdentifier: String = "",
            depth: Int = 0
        ) -> AccessibilityNode {
            AccessibilityNode(
                element: element, role: role, title: title, nodeDescription: description,
                value: value, valueDescription: "", url: url, domIdentifier: domIdentifier,
                hidden: false, depth: depth
            )
        }

        func area(_ index: Int, visibleCount: Int) -> ChromeWatchArea {
            ChromeWatchArea(
                window: window(for: index), windowIndex: index, webArea: webs[index],
                url: pageURL(index), title: "Hulu | Watch", visibleAreaCountInWindow: visibleCount
            )
        }
    }

    func testNativeTabMuteIgnoresStaleChildLabelAndHuluControls() throws {
        let chrome = FakeChrome()
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        let outcome = try client.muteIfCurrentlyMarkedAd(player.identity, expectedPlayers: [player.identity], isCancelled: { false })
        XCTAssertEqual(outcome, .mutedAndVerified)
        XCTAssertEqual(chrome.audioState[0], .muted)
        XCTAssertEqual(chrome.presses, 1)
    }

    func testStateChangingDuringActionValidationCannotToggleBack() throws {
        let chrome = FakeChrome()
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        chrome.onAdvertisedActions = { chrome.audioState[0] = .muted }
        XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(player.identity, expectedPlayers: [player.identity], isCancelled: { false }), .alreadyMuted)
        XCTAssertEqual(chrome.presses, 0)
    }

    func testMarkerDisappearingDuringActionValidationDoesNotPress() throws {
        let chrome = FakeChrome()
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        chrome.onAdvertisedActions = { chrome.markerPresent[0] = false }
        XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(player.identity, expectedPlayers: [player.identity], isCancelled: { false }), .markerDisappeared)
        XCTAssertEqual(chrome.presses, 0)
    }

    func testSplitReselectionDuringFinalMarkerCheckDoesNotPress() throws {
        let chrome = FakeChrome()
        chrome.pageCount = 2
        chrome.split = true
        chrome.duplicateURLs = true
        let client = HuluPlayerClient(chrome: chrome)
        let players = try client.discoverPlayers()
        chrome.onMarkerValueRead = { chrome.selected[1] = false }
        XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(players[0].identity, expectedPlayers: players.map(\.identity), isCancelled: { false }))
        XCTAssertEqual(chrome.presses, 0)
    }

    func testNoTreeTraversalOccursAfterFinalMarkerRead() throws {
        let chrome = FakeChrome()
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        chrome.onMarkerValueRead = { chrome.rejectWindowTraversal = true }
        XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(player.identity, expectedPlayers: [player.identity], isCancelled: { false }), .mutedAndVerified)
        XCTAssertEqual(chrome.presses, 1)
    }

    func testOneSeparateWindowsAndSplitDuplicateURLsMapUniquely() throws {
        let one = FakeChrome()
        XCTAssertEqual(try ChromeTabAudioClient(chrome: one).bind([one.area(0, visibleCount: 1)]).count, 1)

        let separate = FakeChrome()
        separate.pageCount = 2
        separate.duplicateURLs = true
        XCTAssertEqual(try ChromeTabAudioClient(chrome: separate).bind([separate.area(0, visibleCount: 1), separate.area(1, visibleCount: 1)]).count, 2)

        let split = FakeChrome()
        split.pageCount = 2
        split.split = true
        split.duplicateURLs = true
        XCTAssertEqual(try ChromeTabAudioClient(chrome: split).bind([split.area(0, visibleCount: 2), split.area(1, visibleCount: 2)]).count, 2)
    }

    func testAmbiguousOrDisabledOrUnknownNativeAudioNeverPresses() throws {
        let mixed = FakeChrome()
        XCTAssertThrowsError(try ChromeTabAudioClient(chrome: mixed).bind([mixed.area(0, visibleCount: 2)]))

        let disabled = FakeChrome()
        disabled.buttonEnabled = false
        let client = HuluPlayerClient(chrome: disabled)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(player.identity, expectedPlayers: [player.identity], isCancelled: { false }))
        XCTAssertEqual(disabled.presses, 0)

        let unknown = FakeChrome()
        unknown.persistentUnknownAudio = true
        XCTAssertThrowsError(try HuluPlayerClient(chrome: unknown).discoverPlayers())
        XCTAssertEqual(unknown.presses, 0)

        let noAction = FakeChrome()
        noAction.actionAdvertised = false
        let noActionClient = HuluPlayerClient(chrome: noAction)
        let noActionPlayer = try XCTUnwrap(noActionClient.discoverPlayers().first)
        XCTAssertThrowsError(try noActionClient.muteIfCurrentlyMarkedAd(noActionPlayer.identity, expectedPlayers: [noActionPlayer.identity], isCancelled: { false }))
        XCTAssertEqual(noAction.presses, 0)
    }

    func testPostpressConflictingStatusConvergesWithoutRetry() throws {
        let chrome = FakeChrome()
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        chrome.postpressTransientConflictReads = 3
        XCTAssertEqual(try client.muteIfCurrentlyMarkedAd(player.identity, expectedPlayers: [player.identity], isCancelled: { false }), .mutedAndVerified)
        XCTAssertEqual(chrome.presses, 1)
    }

    func testPersistentPostpressUnknownAndUnchangedStateNeverRetry() throws {
        let unknown = FakeChrome()
        unknown.postpressUnknownAudio = true
        let unknownClient = HuluPlayerClient(chrome: unknown, readbackTimeout: 0.02)
        let unknownPlayer = try XCTUnwrap(unknownClient.discoverPlayers().first)
        XCTAssertThrowsError(try unknownClient.muteIfCurrentlyMarkedAd(unknownPlayer.identity, expectedPlayers: [unknownPlayer.identity], isCancelled: { false }))
        XCTAssertEqual(unknown.presses, 1)

        let unchanged = FakeChrome()
        unchanged.mutationChangesState = false
        let unchangedClient = HuluPlayerClient(chrome: unchanged, readbackTimeout: 0.02)
        let unchangedPlayer = try XCTUnwrap(unchangedClient.discoverPlayers().first)
        XCTAssertThrowsError(try unchangedClient.muteIfCurrentlyMarkedAd(unchangedPlayer.identity, expectedPlayers: [unchangedPlayer.identity], isCancelled: { false }))
        XCTAssertEqual(unchanged.presses, 1)
    }

    func testDiscoveryReusesOnlyExactStablePlayerIdentities() throws {
        let chrome = FakeChrome()
        let client = HuluPlayerClient(chrome: chrome)
        let first = try XCTUnwrap(client.discoverPlayers().first)
        let second = try XCTUnwrap(client.discoverPlayers().first)
        XCTAssertEqual(first.identity, second.identity)

        chrome.duplicateURLs = true // Changes the watch URL on the same AX objects.
        let replaced = try XCTUnwrap(client.discoverPlayers().first)
        XCTAssertNotEqual(replaced.identity.token, first.identity.token)
        XCTAssertThrowsError(try client.muteIfCurrentlyMarkedAd(
            first.identity,
            expectedPlayers: [replaced.identity],
            isCancelled: { false }
        ))
    }

    func testSplitDuplicateURLIdentitiesRemainStableAcrossScans() throws {
        let chrome = FakeChrome()
        chrome.pageCount = 2
        chrome.split = true
        chrome.duplicateURLs = true
        let client = HuluPlayerClient(chrome: chrome)
        let first = try client.discoverPlayers()
        let second = try client.discoverPlayers()
        XCTAssertEqual(first.map(\.identity), second.map(\.identity))
        XCTAssertEqual(Set(first.map(\.identity.token)).count, 2)
    }

    func testExactNativeReferenceReplacementAndDisappearanceInvalidateIdentity() throws {
        let windowChrome = FakeChrome()
        let windowClient = HuluPlayerClient(chrome: windowChrome)
        let originalWindow = try XCTUnwrap(windowClient.discoverPlayers().first)
        windowChrome.replaceWindow1 = true
        XCTAssertNotEqual(try XCTUnwrap(windowClient.discoverPlayers().first).identity.token, originalWindow.identity.token)

        let webChrome = FakeChrome()
        let webClient = HuluPlayerClient(chrome: webChrome)
        let originalWeb = try XCTUnwrap(webClient.discoverPlayers().first)
        webChrome.replaceWeb1 = true
        XCTAssertNotEqual(try XCTUnwrap(webClient.discoverPlayers().first).identity.token, originalWeb.identity.token)

        let tabChrome = FakeChrome()
        let tabClient = HuluPlayerClient(chrome: tabChrome)
        let originalTab = try XCTUnwrap(tabClient.discoverPlayers().first)
        tabChrome.replaceTab1 = true
        XCTAssertNotEqual(try XCTUnwrap(tabClient.discoverPlayers().first).identity.token, originalTab.identity.token)

        let buttonChrome = FakeChrome()
        let buttonClient = HuluPlayerClient(chrome: buttonChrome)
        let originalButton = try XCTUnwrap(buttonClient.discoverPlayers().first)
        buttonChrome.replaceButton1 = true
        XCTAssertNotEqual(try XCTUnwrap(buttonClient.discoverPlayers().first).identity.token, originalButton.identity.token)

        let goneChrome = FakeChrome()
        let goneClient = HuluPlayerClient(chrome: goneChrome)
        let disappeared = try XCTUnwrap(goneClient.discoverPlayers().first)
        goneChrome.pageCount = 0
        XCTAssertTrue(try goneClient.discoverPlayers().isEmpty)
        XCTAssertThrowsError(try goneClient.muteIfCurrentlyMarkedAd(
            disappeared.identity,
            expectedPlayers: [],
            isCancelled: { false }
        ))
    }

    func testGuardedUnmuteRequiresFreshCompleteAbsenceAndUsesOnePress() throws {
        let chrome = FakeChrome()
        chrome.markerPresent[0] = false
        chrome.audioState[0] = .muted
        chrome.rejectTraversalAfterPlayerScan = 3
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        XCTAssertEqual(try client.unmuteIfAdMarkerAbsent(
            player.identity,
            expectedPlayers: [player.identity],
            isCancelled: { false }
        ), .unmutedAndVerified)
        XCTAssertEqual(chrome.audioState[0], .playing)
        XCTAssertEqual(chrome.presses, 1)
    }

    func testMarkerReturningDuringUnmutePreparationPreventsPress() throws {
        let chrome = FakeChrome()
        chrome.markerPresent[0] = false
        chrome.audioState[0] = .muted
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        chrome.onAdvertisedActions = { chrome.markerPresent[0] = true }
        XCTAssertEqual(try client.unmuteIfAdMarkerAbsent(
            player.identity,
            expectedPlayers: [player.identity],
            isCancelled: { false }
        ), .markerReappeared)
        XCTAssertEqual(chrome.presses, 0)
    }

    func testUnmuteAlreadyPlayingDisabledUnknownAndNoRetry() throws {
        let playing = FakeChrome()
        playing.markerPresent[0] = false
        playing.buttonEnabled = false
        let playingClient = HuluPlayerClient(chrome: playing)
        let playingPlayer = try XCTUnwrap(playingClient.discoverPlayers().first)
        XCTAssertEqual(try playingClient.unmuteIfAdMarkerAbsent(
            playingPlayer.identity,
            expectedPlayers: [playingPlayer.identity],
            isCancelled: { false }
        ), .alreadyUnmuted)
        XCTAssertEqual(playing.presses, 0)

        let disabled = FakeChrome()
        disabled.markerPresent[0] = false
        disabled.audioState[0] = .muted
        let disabledClient = HuluPlayerClient(chrome: disabled)
        let disabledPlayer = try XCTUnwrap(disabledClient.discoverPlayers().first)
        disabled.buttonEnabled = false
        XCTAssertThrowsError(try disabledClient.unmuteIfAdMarkerAbsent(
            disabledPlayer.identity,
            expectedPlayers: [disabledPlayer.identity],
            isCancelled: { false }
        ))
        XCTAssertEqual(disabled.presses, 0)

        let unknown = FakeChrome()
        unknown.markerPresent[0] = false
        unknown.audioState[0] = .muted
        let unknownClient = HuluPlayerClient(chrome: unknown)
        let unknownPlayer = try XCTUnwrap(unknownClient.discoverPlayers().first)
        unknown.onAdvertisedActions = { unknown.persistentUnknownAudio = true }
        XCTAssertThrowsError(try unknownClient.unmuteIfAdMarkerAbsent(
            unknownPlayer.identity,
            expectedPlayers: [unknownPlayer.identity],
            isCancelled: { false }
        ))
        XCTAssertEqual(unknown.presses, 0)

        let unchanged = FakeChrome()
        unchanged.markerPresent[0] = false
        unchanged.audioState[0] = .muted
        unchanged.mutationChangesState = false
        let unchangedClient = HuluPlayerClient(chrome: unchanged, readbackTimeout: 0.02)
        let unchangedPlayer = try XCTUnwrap(unchangedClient.discoverPlayers().first)
        XCTAssertThrowsError(try unchangedClient.unmuteIfAdMarkerAbsent(
            unchangedPlayer.identity,
            expectedPlayers: [unchangedPlayer.identity],
            isCancelled: { false }
        ))
        XCTAssertEqual(unchanged.presses, 1)
    }

    func testCancellationImmediatelyBeforeUnmutePressDoesNotMutate() throws {
        let chrome = FakeChrome()
        chrome.markerPresent[0] = false
        chrome.audioState[0] = .muted
        let client = HuluPlayerClient(chrome: chrome)
        let player = try XCTUnwrap(client.discoverPlayers().first)
        var checks = 0
        XCTAssertThrowsError(try client.unmuteIfAdMarkerAbsent(
            player.identity,
            expectedPlayers: [player.identity],
            isCancelled: {
                checks += 1
                return checks >= 2
            }
        )) { XCTAssertTrue($0 is MonitoringCancelled) }
        XCTAssertEqual(chrome.presses, 0)
    }
}
