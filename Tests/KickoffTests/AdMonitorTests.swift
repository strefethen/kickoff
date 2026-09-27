import Foundation
import XCTest
@testable import Kickoff

private final class FakePlayerClient: PlayerControlling {
    var players: [PlayerState]
    var discoveries: [[PlayerState]] = []
    var discoveryErrors: [Int: Error] = [:]
    var outcomes: [UUID: Result<MuteMarkedAdOutcome, Error>] = [:]
    var discoverStarted: (() -> Void)?
    var discoverGate: DispatchSemaphore?
    private let lock = NSLock()
    private(set) var muteCalls: [UUID] = []
    private(set) var unmuteCalls: [UUID] = []
    private(set) var discoveryCount = 0
    var unmuteOutcomes: [UUID: Result<UnmuteAfterAdOutcome, Error>] = [:]

    init(players: [PlayerState]) {
        self.players = players
    }

    func unmuteIfAdMarkerAbsent(
        _ player: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> UnmuteAfterAdOutcome {
        if isCancelled() { throw MonitoringCancelled() }
        lock.lock()
        unmuteCalls.append(player.token)
        lock.unlock()
        return try unmuteOutcomes[player.token, default: .success(.unmutedAndVerified)].get()
    }

    func discoverPlayers() throws -> [PlayerState] {
        discoverStarted?()
        discoverGate?.wait()
        lock.lock()
        let index = discoveryCount
        discoveryCount += 1
        lock.unlock()
        if let error = discoveryErrors[index] { throw error }
        return discoveries.isEmpty ? players : discoveries[min(index, discoveries.count - 1)]
    }

    func muteIfCurrentlyMarkedAd(
        _ player: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> MuteMarkedAdOutcome {
        if isCancelled() { throw MonitoringCancelled() }
        lock.lock()
        muteCalls.append(player.token)
        lock.unlock()
        return try outcomes[player.token, default: .success(.mutedAndVerified)].get()
    }

    func calls() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return muteCalls
    }

    func restoreCalls() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return unmuteCalls
    }
}

private final class TestMonotonicClock {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return time
    }
    func advance(_ delta: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        time += delta
    }
}

private enum FakeFailure: Error { case mutationOrReadback }

final class AdMonitorTests: XCTestCase {
    private func player(_ url: String, marked: Bool, muted: Bool = false) -> PlayerState {
        PlayerState(
            identity: PlayerIdentity(token: UUID(), url: url),
            windowIndex: 0,
            muted: muted,
            audioDescription: muted ? "Chrome tab audio muted" : "Chrome tab audio playing",
            hasAdMarker: marked
        )
    }

    private func awaitStatus(
        _ expected: @escaping (AdMonitorStatus) -> Bool,
        monitor: AdMonitor,
        start: () -> Void
    ) {
        let reached = expectation(description: "monitor status")
        monitor.onStatusChange = { status in if expected(status) { reached.fulfill() } }
        start()
        wait(for: [reached], timeout: 2)
        monitor.stopAndDrain()
    }

    func testOnePlayerAdMutesOnce() {
        let ad = player("https://www.hulu.com/watch/one", marked: true)
        let fake = FakePlayerClient(players: [ad])
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 60) { fake }
        awaitStatus({ $0 == .monitoring(players: 1, newlyMuted: 1, newlyUnmuted: 0) }, monitor: monitor) { monitor.start() }
        XCTAssertEqual(fake.calls(), [ad.identity.token])
    }

    func testTwoPlayersIncludingDuplicateURLsRemainDistinctAndBothAdsMute() {
        let first = player("https://www.hulu.com/watch/same", marked: true)
        let second = player("https://www.hulu.com/watch/same", marked: true)
        let fake = FakePlayerClient(players: [first, second])
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 60) { fake }
        awaitStatus({ $0 == .monitoring(players: 2, newlyMuted: 2, newlyUnmuted: 0) }, monitor: monitor) { monitor.start() }
        XCTAssertEqual(Set(fake.calls()), Set([first.identity.token, second.identity.token]))
    }

    func testNoMarkerAndMarkedAlreadyMutedDoNotPress() {
        let game = player("https://www.hulu.com/watch/game", marked: false)
        let mutedAd = player("https://www.hulu.com/watch/ad", marked: true, muted: true)
        let fake = FakePlayerClient(players: [game, mutedAd])
        fake.outcomes[mutedAd.identity.token] = .success(.alreadyMuted)
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 60) { fake }
        awaitStatus({ $0 == .monitoring(players: 2, newlyMuted: 0, newlyUnmuted: 0) }, monitor: monitor) { monitor.start() }
        XCTAssertTrue(fake.calls().isEmpty)
    }

    func testMarkerDisappearingBeforeActionIsSafeNoOp() {
        let ad = player("https://www.hulu.com/watch/ad", marked: true)
        let fake = FakePlayerClient(players: [ad])
        fake.outcomes[ad.identity.token] = .success(.markerDisappeared)
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 60) { fake }
        awaitStatus({ $0 == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 0) }, monitor: monitor) { monitor.start() }
        XCTAssertEqual(fake.calls(), [ad.identity.token])
    }

    func testCancellationWhileScanPendingPreventsMuteAndDrains() {
        let ad = player("https://www.hulu.com/watch/ad", marked: true)
        let fake = FakePlayerClient(players: [ad])
        let gate = DispatchSemaphore(value: 0)
        fake.discoverGate = gate
        let began = expectation(description: "scan began")
        fake.discoverStarted = { began.fulfill() }
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 60) { fake }
        monitor.start()
        wait(for: [began], timeout: 1)
        let drained = expectation(description: "drained")
        monitor.stopAndDrain { drained.fulfill() }
        gate.signal()
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertEqual(monitor.status, .stopped)
    }

    func testMutationOrReadbackFailureStopsMonitoring() {
        let ad = player("https://www.hulu.com/watch/ad", marked: true)
        let fake = FakePlayerClient(players: [ad])
        fake.outcomes[ad.identity.token] = .failure(FakeFailure.mutationOrReadback)
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 60) { fake }
        awaitStatus({ if case .failed = $0 { return true }; return false }, monitor: monitor) { monitor.start() }
        XCTAssertFalse(monitor.isRunning)
    }

    func testStopThenRestartIgnoresStalePassAndSerializesWork() {
        let staleAd = player("https://www.hulu.com/watch/stale", marked: true)
        let currentGame = player("https://www.hulu.com/watch/current", marked: false)
        let first = FakePlayerClient(players: [staleAd])
        let second = FakePlayerClient(players: [currentGame])
        let gate = DispatchSemaphore(value: 0)
        first.discoverGate = gate
        let began = expectation(description: "first began")
        first.discoverStarted = { began.fulfill() }
        let factoryLock = NSLock()
        var factoryCalls = 0
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            factoryLock.lock(); defer { factoryLock.unlock() }
            factoryCalls += 1
            return factoryCalls == 1 ? first : second
        }
        monitor.start()
        wait(for: [began], timeout: 1)
        monitor.stopAndDrain()
        let reached = expectation(description: "new run completed")
        monitor.onStatusChange = { if $0 == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 0) { reached.fulfill() } }
        monitor.start()
        gate.signal()
        wait(for: [reached], timeout: 2)
        XCTAssertTrue(first.calls().isEmpty)
        monitor.stopAndDrain()
    }

    func testOwnedMuteRestoresAfterTwoCompleteAbsenceScans() {
        let identity = PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/owned")
        let ad = PlayerState(identity: identity, windowIndex: 0, muted: false, audioDescription: "playing", hasAdMarker: true)
        let absentMuted = PlayerState(identity: identity, windowIndex: 0, muted: true, audioDescription: "muted", hasAdMarker: false)
        let fake = FakePlayerClient(players: [ad])
        fake.discoveries = [[ad], [absentMuted], [absentMuted]]
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) { fake }
        let restored = expectation(description: "restored")
        monitor.onStatusChange = {
            if $0 == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 1) { restored.fulfill() }
        }
        monitor.start()
        wait(for: [restored], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertEqual(fake.calls(), [identity.token])
        XCTAssertEqual(fake.restoreCalls(), [identity.token])
    }

    func testInitialManualMuteAndNewRunNeverAcquireRestoreOwnership() {
        let manual = player("https://www.hulu.com/watch/manual", marked: false, muted: true)
        let first = FakePlayerClient(players: [manual])
        let second = FakePlayerClient(players: [manual])
        let lock = NSLock()
        var factories = 0
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) {
            lock.lock(); defer { lock.unlock() }
            factories += 1
            return factories == 1 ? first : second
        }
        let firstScans = expectation(description: "first scans")
        firstScans.assertForOverFulfill = false
        monitor.onStatusChange = { _ in if first.discoveryCount >= 3 { firstScans.fulfill() } }
        monitor.start()
        wait(for: [firstScans], timeout: 2)
        let drained = expectation(description: "first drained")
        monitor.stopAndDrain { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        let secondScans = expectation(description: "second scans")
        secondScans.assertForOverFulfill = false
        monitor.onStatusChange = { _ in if second.discoveryCount >= 3 { secondScans.fulfill() } }
        monitor.start()
        wait(for: [secondScans], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertTrue(first.restoreCalls().isEmpty)
        XCTAssertTrue(second.restoreCalls().isEmpty)
    }

    func testStopRestartDiscardsOwnedMuteWithoutCleanupUnmute() {
        let identity = PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/owned")
        let ad = PlayerState(identity: identity, windowIndex: 0, muted: false, audioDescription: "playing", hasAdMarker: true)
        let absentMuted = PlayerState(identity: identity, windowIndex: 0, muted: true, audioDescription: "muted", hasAdMarker: false)
        let first = FakePlayerClient(players: [ad])
        let second = FakePlayerClient(players: [absentMuted])
        let lock = NSLock()
        var factories = 0
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) {
            lock.lock(); defer { lock.unlock() }
            factories += 1
            return factories == 1 ? first : second
        }

        let claimed = expectation(description: "first run claimed mute")
        monitor.onStatusChange = {
            if $0 == .monitoring(players: 1, newlyMuted: 1, newlyUnmuted: 0) { claimed.fulfill() }
        }
        monitor.start()
        wait(for: [claimed], timeout: 1)
        let drained = expectation(description: "drained without cleanup")
        monitor.stopAndDrain { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(first.restoreCalls().isEmpty)

        let rescanned = expectation(description: "fresh run scanned")
        rescanned.assertForOverFulfill = false
        monitor.onStatusChange = { _ in if second.discoveryCount >= 3 { rescanned.fulfill() } }
        monitor.start()
        wait(for: [rescanned], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertTrue(second.restoreCalls().isEmpty)
    }

    func testErrorDiscardsOwnedMuteBeforeFreshRun() {
        let identity = PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/owned")
        let ad = PlayerState(identity: identity, windowIndex: 0, muted: false, audioDescription: "playing", hasAdMarker: true)
        let absentMuted = PlayerState(identity: identity, windowIndex: 0, muted: true, audioDescription: "muted", hasAdMarker: false)
        let failedRun = FakePlayerClient(players: [ad])
        failedRun.discoveryErrors[1] = FakeFailure.mutationOrReadback
        let freshRun = FakePlayerClient(players: [absentMuted])
        let lock = NSLock()
        var factories = 0
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) {
            lock.lock(); defer { lock.unlock() }
            factories += 1
            return factories == 1 ? failedRun : freshRun
        }
        let failed = expectation(description: "run failed")
        monitor.onStatusChange = { if case .failed = $0 { failed.fulfill() } }
        monitor.start()
        wait(for: [failed], timeout: 2)
        XCTAssertTrue(failedRun.restoreCalls().isEmpty)

        let rescanned = expectation(description: "fresh run scanned")
        rescanned.assertForOverFulfill = false
        monitor.onStatusChange = { _ in if freshRun.discoveryCount >= 3 { rescanned.fulfill() } }
        monitor.start()
        wait(for: [rescanned], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertTrue(freshRun.restoreCalls().isEmpty)
    }
    func testTemporaryUnavailableDiscoveryRecoversWithoutRecreatingClient() {
        let ad = player("https://www.peacocktv.com/watch/playback/vod/one", marked: true)
        let fake = FakePlayerClient(players: [ad])
        fake.discoveryErrors = [0: ChromeAudioControlsUnavailable(description: "missing"),
                                1: ChromeAudioControlsUnavailable(description: "missing")]
        var factories = 0
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) {
            factories += 1
            return fake
        }
        let recovered = expectation(description: "recovered")
        var waits = 0
        monitor.onStatusChange = { status in
            if case .waitingForAudioControls = status {
                waits += 1
                XCTAssertTrue(monitor.isRunning)
                XCTAssertTrue(fake.calls().isEmpty)
                XCTAssertTrue(fake.restoreCalls().isEmpty)
            }
            if status == .monitoring(players: 1, newlyMuted: 1, newlyUnmuted: 0) { recovered.fulfill() }
        }
        monitor.start()
        wait(for: [recovered], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(fake.calls(), [ad.identity.token])
    }

    func testUnavailableDiscoveryStopsAtDeadlineBeforeAnotherRead() {
        let fake = FakePlayerClient(players: [])
        fake.discoveryErrors[0] = ChromeAudioControlsUnavailable(description: "missing")
        let clock = TestMonotonicClock()
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01,
                                monotonicTime: clock.now) { fake }
        let failed = expectation(description: "bounded failure")
        monitor.onStatusChange = { status in
            if case .waitingForAudioControls = status { clock.advance(30) }
            if case let .failed(message) = status {
                XCTAssertTrue(message.contains("30 seconds"))
                XCTAssertTrue(message.contains("Resume playback"))
                failed.fulfill()
            }
        }
        monitor.start()
        wait(for: [failed], timeout: 2)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(fake.discoveryCount, 1)
        XCTAssertTrue(fake.calls().isEmpty)
    }

    func testSuccessfulPassResetsUnavailableDeadline() {
        let manual = player("https://www.hulu.com/watch/manual", marked: false, muted: true)
        let fake = FakePlayerClient(players: [manual])
        fake.discoveryErrors = [0: ChromeAudioControlsUnavailable(description: "missing"),
                                2: ChromeAudioControlsUnavailable(description: "missing")]
        let clock = TestMonotonicClock()
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01,
                                monotonicTime: clock.now) { fake }
        let recoveredTwice = expectation(description: "second recovery")
        var waits = 0
        monitor.onStatusChange = { status in
            if case .waitingForAudioControls = status {
                waits += 1
                clock.advance(20)
            }
            if status == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 0), waits == 2 {
                recoveredTwice.fulfill()
            }
        }
        monitor.start()
        wait(for: [recoveredTwice], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertEqual(waits, 2)
        XCTAssertTrue(fake.restoreCalls().isEmpty)
    }

    func testSuccessfulReadFinishingAfterDeadlineCannotMute() {
        let ad = player("https://www.hulu.com/watch/ad", marked: true)
        let fake = FakePlayerClient(players: [ad])
        fake.discoveryErrors[0] = ChromeAudioControlsUnavailable(description: "missing")
        let clock = TestMonotonicClock()
        fake.discoverStarted = { if fake.discoveryCount == 1 { clock.advance(30) } }
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01,
                                monotonicTime: clock.now) { fake }
        awaitStatus({ if case .failed = $0 { return true }; return false }, monitor: monitor) { monitor.start() }
        XCTAssertEqual(fake.discoveryCount, 2)
        XCTAssertTrue(fake.calls().isEmpty)
    }

    func testOwnedMuteSurvivesGapButNeedsTwoFreshCompleteAbsenceScans() {
        let ad = player("https://www.hulu.com/watch/owned", marked: true)
        let absent = PlayerState(identity: ad.identity, windowIndex: 0, muted: true,
                                 audioDescription: "muted", hasAdMarker: false)
        let fake = FakePlayerClient(players: [ad])
        fake.discoveries = [[ad], [absent], [absent], [absent], [absent]]
        fake.discoveryErrors[2] = ChromeAudioControlsUnavailable(description: "missing")
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) { fake }
        let restored = expectation(description: "restored after fresh evidence")
        monitor.onStatusChange = { status in
            if case .waitingForAudioControls = status { XCTAssertTrue(fake.restoreCalls().isEmpty) }
            if status == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 1) {
                XCTAssertEqual(fake.discoveryCount, 5)
                restored.fulfill()
            }
        }
        monitor.start()
        wait(for: [restored], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertEqual(fake.restoreCalls(), [ad.identity.token])
    }

    func testChangedIdentityAfterGapDoesNotRestoreOldOwnedMute() {
        let ad = player("https://www.hulu.com/watch/old", marked: true)
        let replacement = player("https://www.hulu.com/watch/new", marked: false, muted: true)
        let fake = FakePlayerClient(players: [ad])
        fake.discoveries = [[ad], [replacement], [replacement]]
        fake.discoveryErrors[1] = ChromeAudioControlsUnavailable(description: "missing")
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) { fake }
        awaitStatus({ if case .monitoring = $0 { return fake.discoveryCount >= 5 }; return false }, monitor: monitor) { monitor.start() }
        XCTAssertTrue(fake.restoreCalls().isEmpty)
    }

    func testStopDuringAudioWaitThenRestartHasFreshDeadline() {
        let first = FakePlayerClient(players: [])
        first.discoveryErrors[0] = ChromeAudioControlsUnavailable(description: "missing")
        let second = FakePlayerClient(players: [])
        second.discoveryErrors[0] = ChromeAudioControlsUnavailable(description: "missing")
        let clock = TestMonotonicClock()
        var factories = 0
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01,
                                monotonicTime: clock.now) {
            factories += 1
            return factories == 1 ? first : second
        }
        let waited = expectation(description: "first waited")
        monitor.onStatusChange = { if case .waitingForAudioControls = $0 { waited.fulfill() } }
        monitor.start()
        wait(for: [waited], timeout: 2)
        let drained = expectation(description: "cancelled wait drained")
        monitor.stopAndDrain { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        clock.advance(60)
        let recovered = expectation(description: "fresh run recovered")
        monitor.onStatusChange = { if $0 == .waitingForPlayers { recovered.fulfill() } }
        monitor.start()
        wait(for: [recovered], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertEqual(first.discoveryCount, 1)
        XCTAssertEqual(factories, 2)
    }

    func testUnavailableErrorFromMutationIsTerminalAndNeverRetried() {
        let ad = player("https://www.hulu.com/watch/ad", marked: true)
        let fake = FakePlayerClient(players: [ad])
        fake.outcomes[ad.identity.token] = .failure(ChromeAudioControlsUnavailable(description: "action lost control"))
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) { fake }
        awaitStatus({ if case .failed = $0 { return true }; return false }, monitor: monitor) { monitor.start() }
        XCTAssertEqual(fake.discoveryCount, 1)
        XCTAssertEqual(fake.calls(), [ad.identity.token])
    }

    func testProductionPeacockClientRecoversThenMutesAndRestoresOnce() {
        let chrome = HuluPlayerPrepressTests.FakeChrome()
        chrome.providers = [.peacock, .hulu]
        chrome.videoIdentifier = "core-video-tape"
        chrome.missingAudioButton = true
        let monitor = AdMonitor(operationQueue: DispatchQueue(label: #function), interval: 0.01) {
            ChromePlayerClient(chrome: chrome)
        }
        let restored = expectation(description: "production path restored")
        var waitingObserved = false
        monitor.onStatusChange = { status in
            if case .waitingForAudioControls = status {
                waitingObserved = true
                XCTAssertEqual(chrome.presses, 0)
                chrome.missingAudioButton = false
            }
            if status == .monitoring(players: 1, newlyMuted: 1, newlyUnmuted: 0) {
                chrome.markerPresent[0] = false
            }
            if status == .monitoring(players: 1, newlyMuted: 0, newlyUnmuted: 1) { restored.fulfill() }
        }
        monitor.start()
        wait(for: [restored], timeout: 2)
        monitor.stopAndDrain()
        XCTAssertTrue(waitingObserved)
        XCTAssertEqual(chrome.presses, 2)
        XCTAssertEqual(chrome.audioState[0], .playing)
    }

}
