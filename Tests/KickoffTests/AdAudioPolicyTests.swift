import Foundation
import XCTest
@testable import Kickoff

final class AdAudioPolicyTests: XCTestCase {
    private func state(_ identity: PlayerIdentity, marked: Bool, muted: Bool) -> PlayerState {
        PlayerState(
            identity: identity,
            windowIndex: 0,
            muted: muted,
            audioDescription: muted ? "muted" : "playing",
            hasAdMarker: marked
        )
    }

    func testAbsenceMustBeConsecutiveAndMarkerResetsCounter() {
        let identity = PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/a")
        let policy = AdAudioPolicy()
        policy.claimAfterVerifiedMute(identity)
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: false, muted: true)]).isEmpty)
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: true, muted: true)]).isEmpty)
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: false, muted: true)]).isEmpty)
        XCTAssertEqual(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: false, muted: true)]), [identity])
    }

    func testObservedExternalUnmuteDropsLeaseEvenWhenAdIsPresent() {
        let identity = PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/a")
        let policy = AdAudioPolicy()
        policy.claimAfterVerifiedMute(identity)
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: true, muted: false)]).isEmpty)
        XCTAssertFalse(policy.owns(identity))
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: false, muted: true)]).isEmpty)
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: [state(identity, marked: false, muted: true)]).isEmpty)
    }

    func testDisappearedIdentityPrunesLease() {
        let identity = PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/a")
        let policy = AdAudioPolicy()
        policy.claimAfterVerifiedMute(identity)
        XCTAssertTrue(policy.restoreCandidates(afterCompleteScan: []).isEmpty)
        XCTAssertFalse(policy.owns(identity))
    }
}
