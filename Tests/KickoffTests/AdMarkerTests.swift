import ApplicationServices
import XCTest
@testable import Kickoff

final class AdMarkerTests: XCTestCase {
    func testExactPositiveMarkersAndNearMisses() {
        ["Ad", "Ad 0:05", "Ad 12:59"].forEach { XCTAssertTrue(AdMarker.matches($0), $0) }
        [" ad", "Ad ", "Ad 1:5", "Ad 1:60", "Ads", "Advertisement", "Ad 0:05 remaining"].forEach {
            XCTAssertFalse(AdMarker.matches($0), $0)
        }
    }

    func testOnlyPlayerScopedStaticTextCanMarkAnAd() {
        let unrelatedPageNodes = [PlayerContentNode(role: kAXStaticTextRole, value: "Ad")]
        let playerNodes = [
            PlayerContentNode(role: kAXButtonRole, value: "Ad"),
            PlayerContentNode(role: kAXStaticTextRole, value: "Ad choices"),
        ]
        XCTAssertTrue(AdMarker.isPresent(inPlayerNodes: unrelatedPageNodes))
        XCTAssertFalse(AdMarker.isPresent(inPlayerNodes: playerNodes))
        // Production passes only descendants of the unique non-hidden
        // __player__; page-level aggregate text is intentionally excluded.
        XCTAssertFalse(AdMarker.isPresent(inPlayerNodes: playerNodes))
    }

    func testHuluWatchURLRequiresExactHostAndWatchPath() {
        XCTAssertTrue(HuluPlayerClient.isHuluWatchURL("https://www.hulu.com/watch/abc"))
        XCTAssertTrue(HuluPlayerClient.isHuluWatchURL("https://hulu.com/watch/abc"))
        XCTAssertFalse(HuluPlayerClient.isHuluWatchURL("https://example.com/watch/abc"))
        XCTAssertFalse(HuluPlayerClient.isHuluWatchURL("https://www.hulu.com/live"))
        XCTAssertFalse(HuluPlayerClient.isHuluWatchURL("http://www.hulu.com/watch/abc"))
    }
}
