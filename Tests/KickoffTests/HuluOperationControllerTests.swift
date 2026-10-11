import Foundation
import XCTest
@testable import Kickoff

final class HuluOperationControllerTests: XCTestCase {
    private enum StubError: Error {
        case expected
    }

    private final class EmptyClient: PlayerControlling {
        let failsAction: Bool
        init(failsAction: Bool = false) { self.failsAction = failsAction }
        func discoverPlayers() throws -> [PlayerState] {
            failsAction ? [PlayerState(identity: PlayerIdentity(token: UUID(), url: "https://www.hulu.com/watch/test"),
                                      windowIndex: 0, muted: false, audioDescription: "playing", hasAdMarker: true)] : []
        }
        func muteIfCurrentlyMarkedAd(
            _ player: PlayerIdentity,
            expectedPlayers: [PlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> MuteMarkedAdOutcome {
            if failsAction { throw StubError.expected }
            return .markerDisappeared
        }
        func unmuteIfAdMarkerAbsent(
            _ player: PlayerIdentity,
            expectedPlayers: [PlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> UnmuteAfterAdOutcome { .markerReappeared }
    }

    private final class BlockingClient: PlayerControlling {
        let started: XCTestExpectation
        let gate: DispatchSemaphore
        init(started: XCTestExpectation, gate: DispatchSemaphore) {
            self.started = started
            self.gate = gate
        }
        func discoverPlayers() throws -> [PlayerState] {
            started.fulfill()
            gate.wait()
            return []
        }
        func muteIfCurrentlyMarkedAd(
            _ player: PlayerIdentity,
            expectedPlayers: [PlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> MuteMarkedAdOutcome { .markerDisappeared }
        func unmuteIfAdMarkerAbsent(
            _ player: PlayerIdentity,
            expectedPlayers: [PlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> UnmuteAfterAdOutcome { .markerReappeared }
    }

    private func defaults() -> UserDefaults {
        let suite = "HuluOperationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTrustedLaunchStartsDefaultMonitoring() {
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in {} }
        )

        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)

        XCTAssertTrue(controller.isMonitoring)
        controller.stopMonitoring()
    }

    func testUntrustedLaunchDefersDefaultUntilTrustedAndStartsOnlyOnce() {
        let queue = DispatchQueue(label: #function)
        let clientCreated = expectation(description: "client created")
        clientCreated.assertForOverFulfill = true
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            clientCreated.fulfill()
            return EmptyClient()
        }
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in {} }
        )

        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: false)
        XCTAssertFalse(controller.isMonitoring)

        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)

        XCTAssertTrue(controller.isMonitoring)
        wait(for: [clientCreated], timeout: 1)
        controller.stopMonitoring()
    }

    func testManualToggleStopRemainsStoppedOnLaterDefaultCheck() {
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in {} }
        )

        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        XCTAssertTrue(controller.isMonitoring)

        controller.toggleMonitoring(accessibilityTrusted: true)
        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)

        XCTAssertFalse(controller.isMonitoring)

        let drained = expectation(description: "monitor drained")
        controller.stopMonitoring { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testFactoryFailureKeepsIntentAndRecoversWithoutExplicitRetry() {
        let queue = DispatchQueue(label: #function)
        var factories = 0
        let monitor = AdMonitor(operationQueue: queue, interval: 60, discoveryRetryInterval: 0.01) {
            factories += 1
            if factories == 1 { throw StubError.expected }
            return EmptyClient()
        }
        let controller = HuluOperationController(monitor: monitor, operationQueue: queue, prepareSetup: { _ in {} })
        let recovered = expectation(description: "automatically recovered")
        controller.onChange = {
            if case .recovering = controller.monitorStatus {
                XCTAssertTrue(controller.isMonitoring)
                XCTAssertTrue(controller.isAdMutingEnabled)
                XCTAssertFalse(controller.canRetryAdMuting)
            }
            if controller.monitorStatus == .waitingForPlayers { recovered.fulfill() }
        }
        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        wait(for: [recovered], timeout: 1)
        XCTAssertEqual(factories, 2)
        controller.stopMonitoring()
    }

    func testTerminalErrorPreservesIntentAndOnlyExplicitRetryRestarts() {
        let queue = DispatchQueue(label: #function)
        var factories = 0
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            factories += 1
            return EmptyClient(failsAction: factories == 1)
        }
        let controller = HuluOperationController(monitor: monitor, operationQueue: queue, prepareSetup: { _ in {} })
        let failed = expectation(description: "failed with enabled intent")
        controller.onChange = { if case .failed = controller.monitorStatus { failed.fulfill() } }
        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        wait(for: [failed], timeout: 1)
        XCTAssertTrue(controller.isAdMutingEnabled)
        XCTAssertFalse(controller.isMonitoring)
        controller.retryAdMuting(accessibilityTrusted: false)
        XCTAssertFalse(controller.isMonitoring)
        let resumed = expectation(description: "explicit retry recovered")
        controller.onChange = { if controller.monitorStatus == .waitingForPlayers { resumed.fulfill() } }
        controller.retryAdMuting(accessibilityTrusted: true)
        wait(for: [resumed], timeout: 1)
        XCTAssertTrue(controller.isAdMutingEnabled)
        XCTAssertFalse(controller.canRetryAdMuting)
        controller.toggleMonitoring(accessibilityTrusted: true)
        XCTAssertFalse(controller.isAdMutingEnabled)
        controller.retryAdMuting(accessibilityTrusted: true)
        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        XCTAssertFalse(controller.isMonitoring)
        XCTAssertEqual(factories, 2)
    }

    func testPreparedSetupResumesDefaultIntentAndQuitConsumesPendingStart() {
        let setupQueue = DispatchQueue(label: "\(#function).setup")
        let setupMonitor = AdMonitor(operationQueue: setupQueue, interval: 60) { EmptyClient() }
        let setupFinished = expectation(description: "setup finished")
        let setupController = HuluOperationController(
            monitor: setupMonitor,
            operationQueue: setupQueue,
            prepareSetup: { _ in {} }
        )
        setupController.onChange = {
            if setupController.status == "Chrome setup complete" { setupFinished.fulfill() }
        }

        setupController.startSetup()
        wait(for: [setupFinished], timeout: 1)
        setupController.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        XCTAssertTrue(setupController.isAdMutingEnabled)
        XCTAssertTrue(setupController.isMonitoring)
        setupController.stopMonitoring()

        let quitQueue = DispatchQueue(label: "\(#function).quit")
        let quitMonitor = AdMonitor(operationQueue: quitQueue, interval: 60) { EmptyClient() }
        let quitFinished = expectation(description: "quit finished")
        let quitController = HuluOperationController(
            monitor: quitMonitor,
            operationQueue: quitQueue,
            prepareSetup: { _ in {} }
        )

        quitController.stopForQuit { quitFinished.fulfill() }
        wait(for: [quitFinished], timeout: 1)
        quitController.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        XCTAssertFalse(quitController.isMonitoring)
    }

    func testSetupWaitsForMonitorDrainAndMonitoringCannotRestartDuringSetup() {
        let queue = DispatchQueue(label: #function)
        let scanBegan = expectation(description: "scan began")
        let gate = DispatchSemaphore(value: 0)
        var factories = 0
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            factories += 1
            return factories == 1 ? BlockingClient(started: scanBegan, gate: gate) : EmptyClient()
        }
        let setupRan = expectation(description: "setup ran")
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in { setupRan.fulfill() } }
        )
        var setupNotificationMonitoringStates: [Bool] = []
        controller.onChange = {
            if controller.isSettingUp {
                setupNotificationMonitoringStates.append(controller.isMonitoring)
            }
        }
        controller.startMonitoring()
        wait(for: [scanBegan], timeout: 1)
        controller.startSetup()
        controller.startMonitoring()
        XCTAssertTrue(controller.isSettingUp)
        XCTAssertFalse(controller.isMonitoring)
        XCTAssertEqual(setupNotificationMonitoringStates.first, false)
        XCTAssertEqual(setupRan.expectedFulfillmentCount, 1)
        gate.signal()
        wait(for: [setupRan], timeout: 1)
    }

    func testQuitWhileSetupIsWaitingForDrainDoesNotEnqueueSetup() {
        let queue = DispatchQueue(label: #function)
        let scanBegan = expectation(description: "scan began")
        let gate = DispatchSemaphore(value: 0)
        var factories = 0
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            factories += 1
            return factories == 1 ? BlockingClient(started: scanBegan, gate: gate) : EmptyClient()
        }
        let setupDidNotRun = expectation(description: "setup did not run")
        setupDidNotRun.isInverted = true
        let quitCompleted = expectation(description: "quit completed")
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in { setupDidNotRun.fulfill() } }
        )
        controller.startMonitoring()
        wait(for: [scanBegan], timeout: 1)
        controller.startSetup()
        controller.stopForQuit { quitCompleted.fulfill() }
        gate.signal()
        wait(for: [quitCompleted, setupDidNotRun], timeout: 0.5)
        XCTAssertTrue(controller.isQuitting)
    }

    func testAdMutingToggleRequiresPermissionOnlyToStart() {
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in {} }
        )

        controller.toggleMonitoring(accessibilityTrusted: false)
        XCTAssertFalse(controller.isMonitoring)

        controller.toggleMonitoring(accessibilityTrusted: true)
        XCTAssertTrue(controller.isMonitoring)

        // Revoked permission must not trap a running monitor in the on state.
        controller.toggleMonitoring(accessibilityTrusted: false)
        XCTAssertFalse(controller.isMonitoring)

        let drained = expectation(description: "monitor drained")
        controller.stopMonitoring { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testSetupJobCapturesWebsiteAtInvocationBeforeMonitorDrain() throws {
        let queue = DispatchQueue(label: #function)
        let scanBegan = expectation(description: "scan began")
        let gate = DispatchSemaphore(value: 0)
        var factories = 0
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            factories += 1
            return factories == 1 ? BlockingClient(started: scanBegan, gate: gate) : EmptyClient()
        }
        let setupRan = expectation(description: "setup ran")
        let preferences = WebsitePreferences(defaults: defaults())
        let initialDraft = preferences.makeDraft()
        initialDraft.update("https://first.example/path")
        try initialDraft.save()
        var capturedWebsite: WebsiteURL?
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { mode in
                XCTAssertEqual(mode, .quad)
                let website = try preferences.currentURL()
                capturedWebsite = website
                return {
                    XCTAssertEqual(website.absoluteString, "https://first.example/path")
                    setupRan.fulfill()
                }
            }
        )

        controller.startMonitoring()
        wait(for: [scanBegan], timeout: 1)
        controller.startSetup(mode: .quad)
        let nextDraft = preferences.makeDraft()
        nextDraft.update("https://second.example/path")
        try nextDraft.save()

        XCTAssertEqual(capturedWebsite?.absoluteString, "https://first.example/path")
        gate.signal()
        wait(for: [setupRan], timeout: 1)
    }

    func testSetupFailureResumesEnabledMonitoring() {
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
        let controller = HuluOperationController(monitor: monitor, operationQueue: queue,
                                                 prepareSetup: { _ in { throw StubError.expected } })
        let failed = expectation(description: "setup failure reported")
        controller.onSetupFailure = { _ in
            XCTAssertTrue(controller.isMonitoring, "Resume before a modal setup-failure alert")
            failed.fulfill()
        }
        controller.startMonitoring()
        controller.startSetup()
        XCTAssertTrue(controller.isAdMutingEnabled)
        XCTAssertFalse(controller.isMonitoring)
        wait(for: [failed], timeout: 1)
        XCTAssertTrue(controller.isMonitoring)
        controller.stopMonitoring()
    }

    func testExplicitOffBeforeOrDuringSetupPreventsResume() {
        for stopDuringSetup in [false, true] {
            let queue = DispatchQueue(label: "\(#function).\(stopDuringSetup)")
            let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
            let controller = HuluOperationController(monitor: monitor, operationQueue: queue, prepareSetup: { _ in {} })
            let finished = expectation(description: "setup finished")
            controller.onChange = { if controller.status == "Chrome setup complete" { finished.fulfill() } }
            if !stopDuringSetup { controller.stopMonitoring() }
            controller.startSetup()
            if stopDuringSetup { controller.stopMonitoring() }
            wait(for: [finished], timeout: 1)
            XCTAssertFalse(controller.isAdMutingEnabled)
            XCTAssertFalse(controller.isMonitoring)
        }
    }

    func testInvalidPreparationLeavesPendingDefaultStart() {
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
        let controller = HuluOperationController(monitor: monitor, operationQueue: queue,
                                                 prepareSetup: { _ in throw StubError.expected })
        controller.startSetup()
        XCTAssertFalse(controller.isSettingUp)
        XCTAssertTrue(controller.isAdMutingEnabled)
        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        XCTAssertTrue(controller.isMonitoring)
        controller.stopMonitoring()
    }

    func testQuitDuringRunningSetupPreventsResume() {
        let queue = DispatchQueue(label: #function)
        let monitor = AdMonitor(operationQueue: queue, interval: 60) { EmptyClient() }
        let began = expectation(description: "setup began")
        let gate = DispatchSemaphore(value: 0)
        let controller = HuluOperationController(monitor: monitor, operationQueue: queue,
                                                 prepareSetup: { _ in { began.fulfill(); gate.wait() } })
        controller.startSetup()
        wait(for: [began], timeout: 1)
        let quit = expectation(description: "quit drained")
        controller.stopForQuit { quit.fulfill() }
        gate.signal()
        wait(for: [quit], timeout: 1)
        controller.startSetup()
        XCTAssertFalse(controller.isMonitoring)
        XCTAssertFalse(controller.isAdMutingEnabled)
        XCTAssertFalse(controller.isSettingUp)
    }
}
