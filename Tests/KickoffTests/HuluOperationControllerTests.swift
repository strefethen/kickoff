import Foundation
import XCTest
@testable import Kickoff

final class HuluOperationControllerTests: XCTestCase {
    private enum StubError: Error {
        case expected
    }

    private final class EmptyClient: HuluPlayerControlling {
        func discoverPlayers() throws -> [HuluPlayerState] { [] }
        func muteIfCurrentlyMarkedAd(
            _ player: HuluPlayerIdentity,
            expectedPlayers: [HuluPlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> MuteMarkedAdOutcome { .markerDisappeared }
        func unmuteIfAdMarkerAbsent(
            _ player: HuluPlayerIdentity,
            expectedPlayers: [HuluPlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> UnmuteAfterAdOutcome { .markerReappeared }
    }

    private final class BlockingClient: HuluPlayerControlling {
        let started: XCTestExpectation
        let gate: DispatchSemaphore
        init(started: XCTestExpectation, gate: DispatchSemaphore) {
            self.started = started
            self.gate = gate
        }
        func discoverPlayers() throws -> [HuluPlayerState] {
            started.fulfill()
            gate.wait()
            return []
        }
        func muteIfCurrentlyMarkedAd(
            _ player: HuluPlayerIdentity,
            expectedPlayers: [HuluPlayerIdentity],
            isCancelled: () -> Bool
        ) throws -> MuteMarkedAdOutcome { .markerDisappeared }
        func unmuteIfAdMarkerAbsent(
            _ player: HuluPlayerIdentity,
            expectedPlayers: [HuluPlayerIdentity],
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

    func testMonitorErrorDoesNotRetryPendingDefaultStart() {
        let queue = DispatchQueue(label: #function)
        let failed = expectation(description: "monitor failed")
        let retried = expectation(description: "monitor did not retry")
        retried.isInverted = true
        var factoryCalls = 0
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            factoryCalls += 1
            if factoryCalls > 1 { retried.fulfill() }
            throw StubError.expected
        }
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: queue,
            prepareSetup: { _ in {} }
        )
        controller.onChange = {
            if case .failed = controller.monitorStatus { failed.fulfill() }
        }

        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        wait(for: [failed], timeout: 1)
        XCTAssertFalse(controller.isMonitoring)

        controller.startDefaultMonitoringIfNeeded(accessibilityTrusted: true)
        wait(for: [retried], timeout: 0.05)
        XCTAssertEqual(factoryCalls, 1)
    }

    func testSetupAndQuitConsumePendingDefaultStart() {
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
        XCTAssertFalse(setupController.isMonitoring)

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
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            BlockingClient(started: scanBegan, gate: gate)
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
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            BlockingClient(started: scanBegan, gate: gate)
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
        let monitor = AdMonitor(operationQueue: queue, interval: 60) {
            BlockingClient(started: scanBegan, gate: gate)
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
}
