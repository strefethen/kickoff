import ApplicationServices
import XCTest
@testable import Kickoff

final class PlayerAdDetectionTests: XCTestCase {
    private typealias FakeChrome = HuluPlayerPrepressTests.FakeChrome

    private func node(
        _ element: AXUIElement = AXUIElementCreateApplication(900),
        role: String = kAXGroupRole, value: String = "", id: String = "",
        hidden: Bool = false, depth: Int = 1, classes: [String] = []
    ) -> AccessibilityNode {
        AccessibilityNode(element: element, role: role, title: "", nodeDescription: "",
                          value: value, valueDescription: "", url: nil, domIdentifier: id,
                          hidden: hidden, depth: depth, domClassList: classes)
    }

    func testExactProviderRoutesAndPeacockNonemptySuffix() {
        for host in ["peacocktv.com", "www.peacocktv.com"] {
            XCTAssertEqual(PlayerAdDetection.provider(for: "https://\(host)/watch/playback/vod/_/abc?paused=true"), .peacock)
        }
        for url in ["http://www.peacocktv.com/watch/playback/abc",
                    "https://www.peacocktv.com/watch/playback/",
                    "https://www.peacocktv.com/watch/playback",
                    "https://www.peacocktv.com/watch/abc",
                    "https://www.peacocktv.com/browse",
                    "https://www.peacocktv.com.evil.test/watch/playback/abc",
                    "https://evil-peacocktv.com/watch/playback/abc",
                    "https://other.peacocktv.com/watch/playback/abc",
                    "https://www.hulu.com.evil.test/watch/abc"] {
            XCTAssertNil(PlayerAdDetection.provider(for: url), url)
        }
        // Foundation normalizes the trailing slash, preserving Hulu's existing rule.
        XCTAssertNil(PlayerAdDetection.provider(for: "https://hulu.com/watch/"))
    }

    func testSemanticClassesAllowBuildChangesButRequireBothExactTokens() {
        for classes in [["pffOverlay", "adBreakActive"],
                        ["pffOverlay-p7makt", "adBreakActive-wCpMdn"],
                        ["other", "adBreakActive-newBuild", "pffOverlay-newBuild"]] {
            XCTAssertTrue(PlayerAdDetection.activeOverlay(classes: classes))
        }
        for classes in [[String](), ["pffOverlay-build"], ["adBreakActive-build"],
                        ["pffOverlay-", "adBreakActive-build"],
                        ["pffOverlay-build", "adBreakActive-"],
                        ["xpffOverlay-build", "adBreakActive-build"],
                        ["pffOverlay-build", "xadBreakActive-build"],
                        ["pffOverlay-build adBreakActive-build"],
                        ["pffOverlay-build", "adBreakInactive-build"],
                        ["PffOverlay-build", "adBreakActive-build"]] {
            XCTAssertFalse(PlayerAdDetection.activeOverlay(classes: classes), "\(classes)")
        }
    }

    func testDigitsStaticTextAndHiddenGroupsCannotMarkPeacockAds() {
        let active = ["pffOverlay-build", "adBreakActive-build"]
        XCTAssertTrue(PlayerAdDetection.peacock.isMarker(node(classes: active)))
        XCTAssertFalse(PlayerAdDetection.peacock.isMarker(node(value: "26")))
        XCTAssertFalse(PlayerAdDetection.peacock.isMarker(node(role: kAXStaticTextRole, value: "Ad 26", classes: active)))
        XCTAssertFalse(PlayerAdDetection.peacock.isMarker(node(hidden: true, classes: active)))
        XCTAssertFalse(PlayerAdDetection.hulu.isMarker(node(value: "Ad", classes: active)))
        XCTAssertTrue(PlayerAdDetection.hulu.isMarker(node(role: kAXStaticTextRole, value: "aD 26")))
    }

    func testUniqueVisibleVideoAnchorRequiredEvenForAbsence() throws {
        for (count, hidden) in [(0, false), (2, false), (1, true)] {
            let chrome = FakeChrome()
            chrome.providers[0] = .peacock
            chrome.markerPresent[0] = false
            chrome.videoCount = count
            chrome.videoHidden = hidden
            XCTAssertThrowsError(try ChromePlayerClient(chrome: chrome).discoverPlayers())
        }
        let chrome = FakeChrome()
        chrome.providers[0] = .peacock
        chrome.markerPresent[0] = false
        XCTAssertFalse(try XCTUnwrap(ChromePlayerClient(chrome: chrome).discoverPlayers().first).hasAdMarker)
    }

    func testMissingAmbiguousHiddenAndNestedPlayerRootsAreIncomplete() {
        let chrome = FakeChrome()
        let root = node(chrome.root1, id: "mainContainer")
        let second = node(chrome.root2, id: "mainContainer")
        let hidden = node(chrome.root1, id: "mainContainer", hidden: true)
        let nested = node(chrome.web2, role: "AXWebArea", depth: 1)
        let nestedRoot = node(chrome.root1, id: "mainContainer", depth: 2)
        for roots in [[], [root, second], [hidden], [nested, nestedRoot]] {
            chrome.areaNodesOverride = roots
            XCTAssertThrowsError(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome))
        }
    }

    func testNestedVideoCannotCompletePlayerAndNestedOverlayCannotSupplyMarker() throws {
        let chrome = FakeChrome()
        chrome.providers[0] = .peacock
        let root = node(chrome.root1, id: "mainContainer", depth: 0)
        let nested = node(chrome.web2, role: "AXWebArea", depth: 1)
        let nestedVideo = node(chrome.video2, id: "core-video-shaka", depth: 2)
        let nestedOverlay = node(chrome.marker2, depth: 2, classes: ["pffOverlay-x", "adBreakActive-x"])
        chrome.contentNodesOverride = [root, nested, nestedVideo, nestedOverlay]
        XCTAssertThrowsError(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome))
        chrome.contentNodesOverride = [root, node(chrome.video1, id: "core-video-shaka"), nested, nestedVideo, nestedOverlay]
        XCTAssertTrue(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome).markers.isEmpty)
    }

    func testIncompleteTraversalAndFailedClassReadsAreFailuresNotAbsence() {
        let chrome = FakeChrome()
        chrome.providers[0] = .peacock
        chrome.markerPresent[0] = false
        chrome.incompletePlayerScan = true
        XCTAssertThrowsError(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome))
        chrome.incompletePlayerScan = false
        chrome.classReadFailure = true
        XCTAssertThrowsError(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome))
        chrome.classReadFailure = false
        chrome.malformedClassList = true
        XCTAssertThrowsError(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome))
    }

    func testHiddenAncestorMakesOverlayInvisibleWithinCompleteScan() throws {
        let chrome = FakeChrome()
        chrome.providers[0] = .peacock
        chrome.ancestorHidden = true
        XCTAssertTrue(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome).markers.isEmpty)
    }

    func testMonitoringMessagesDescribeSupportedPlayers() {
        XCTAssertEqual(AdMonitorStatus.scanning.message, "Checking Chrome players…")
        XCTAssertEqual(AdMonitorStatus.waitingForPlayers.message, "Ad muting — waiting for a Chrome player")
        XCTAssertEqual(AdMonitorStatus.monitoring(players: 2, newlyMuted: 1, newlyUnmuted: 1).message,
                       "Ad muting 2 Chrome players — muted 1 ad, restored 1 player")
    }
    func testBothExactPeacockAnchorsSupportAdAndNormalContent() throws {
        for identifier in ["core-video-shaka", "core-video-tape"] {
            for marked in [false, true] {
                let chrome = FakeChrome()
                chrome.providers[0] = .peacock
                chrome.videoIdentifier = identifier
                chrome.markerPresent[0] = marked
                let evidence = try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome)
                XCTAssertNotNil(evidence.requiredAnchor)
                XCTAssertEqual(evidence.requiredAnchorIdentifier, identifier)
                XCTAssertEqual(!evidence.markers.isEmpty, marked)
                XCTAssertEqual(try PlayerAdDetection.peacock.markerIsStillPresent(evidence, chrome: chrome), marked)
                XCTAssertEqual(try XCTUnwrap(ChromePlayerClient(chrome: chrome).discoverPlayers().first).hasAdMarker, marked)
            }
        }
    }

    func testPeacockMixedDuplicateWrongHiddenAndNestedAnchorsAreIncomplete() {
        let chrome = FakeChrome()
        chrome.providers[0] = .peacock
        let root = node(chrome.root1, id: "mainContainer", depth: 0)
        let shaka = node(chrome.video1, id: "core-video-shaka")
        let tape = node(chrome.video2, id: "core-video-tape")
        let nested = node(chrome.web2, role: "AXWebArea", depth: 1)
        for anchors in [
            [], [shaka, tape],
            [shaka, node(chrome.video2, id: "core-video-shaka")],
            [tape, node(chrome.video1, id: "core-video-tape")],
            [node(chrome.video1, id: "core-video-other")],
            [node(chrome.video1, id: "core-video-tape-extra")],
            [node(chrome.video1, id: "core-video-shaka", hidden: true)],
            [node(chrome.video1, id: "core-video-tape", hidden: true)],
            [nested, node(chrome.video1, id: "core-video-shaka", depth: 2)],
            [nested, node(chrome.video1, id: "core-video-tape", depth: 2)]
        ] {
            chrome.contentNodesOverride = [root] + anchors
            XCTAssertThrowsError(try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome))
        }
    }

    func testVideoBranchAncestorsAreRetainedSeparatelyFromOverlayBranch() throws {
        for identifier in ["core-video-shaka", "core-video-tape"] {
            let chrome = FakeChrome()
            chrome.providers[0] = .peacock
            chrome.videoIdentifier = identifier
            let evidence = try PlayerAdDetection.peacock.read(in: chrome.web1, chrome: chrome)
            XCTAssertEqual(evidence.requiredAnchorAncestors.count, 3)
            XCTAssertTrue(CFEqual(evidence.requiredAnchorAncestors[0], chrome.root1))
            XCTAssertTrue(CFEqual(evidence.requiredAnchorAncestors[1], chrome.videoAncestor1))
            XCTAssertTrue(CFEqual(evidence.requiredAnchorAncestors[2], chrome.videoAncestor2))
            XCTAssertFalse(evidence.markers[0].ancestors.contains { CFEqual($0, chrome.videoAncestor1) || CFEqual($0, chrome.videoAncestor2) })
            XCTAssertTrue(try PlayerAdDetection.peacock.markerIsStillPresent(evidence, chrome: chrome))
            chrome.videoAncestorHidden[1] = true
            XCTAssertFalse(try PlayerAdDetection.peacock.markerIsStillPresent(evidence, chrome: chrome))
        }
    }

}
