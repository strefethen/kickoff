import ApplicationServices
import XCTest
@testable import Kickoff

final class AdMarkerTests: XCTestCase {
    func testPrefixIgnoresCaseAndDoesNotParseTrailingText() {
        for prefix in ["Ad", "ad", "AD", "aD"] {
            for suffix in ["", " ", " 0:05", " 12:59", " 1:60", " 1:5", "s",
                           "vertisement", " choices", " remaining", "\n", "\r\n",
                           "🏈", String(repeating: "x", count: 4_096)] {
                XCTAssertTrue(AdMarker.matches(prefix + suffix), (prefix + suffix).debugDescription)
            }
        }
    }

    func testPrefixMustBeginAtTheStartOfTheText() {
        for value in ["", "a", "d", " ad", " AD", "\tAd", "\nAd", "Read", "bad",
                      "Play", "📺Ad", "\u{200B}Ad", "A d", "A\u{0301}d"] {
            XCTAssertFalse(AdMarker.matches(value), value.debugDescription)
        }
    }

    func testOnlyPlayerScopedStaticTextCanMarkAnAd() {
        let unrelatedPageNodes = [PlayerContentNode(role: kAXStaticTextRole, value: "Ad")]
        let playerNodes = [
            PlayerContentNode(role: kAXButtonRole, value: "AD"),
            PlayerContentNode(role: kAXStaticTextRole, value: "Read about ads"),
        ]
        XCTAssertTrue(AdMarker.isPresent(inPlayerNodes: unrelatedPageNodes))
        // Production passes only descendants of the unique non-hidden
        // __player__; page-level aggregate text is intentionally excluded.
        XCTAssertFalse(AdMarker.isPresent(inPlayerNodes: playerNodes))
        XCTAssertTrue(AdMarker.isPresent(inPlayerNodes: [
            PlayerContentNode(role: kAXStaticTextRole, value: "aD anything"),
        ]))
    }

    func testHuluWatchURLRequiresExactHostAndWatchPath() {
        XCTAssertEqual(PlayerAdDetection.provider(for: "https://www.hulu.com/watch/abc"), .hulu)
        XCTAssertEqual(PlayerAdDetection.provider(for: "https://hulu.com/watch/abc"), .hulu)
        XCTAssertNil(PlayerAdDetection.provider(for: "https://example.com/watch/abc"))
        XCTAssertNil(PlayerAdDetection.provider(for: "https://www.hulu.com/live"))
        XCTAssertNil(PlayerAdDetection.provider(for: "http://www.hulu.com/watch/abc"))
    }
}
