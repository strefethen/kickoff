import Foundation

enum AdMonitorStatus: Equatable {
    case stopped
    case scanning
    case waitingForPlayers
    case waitingForPlayback
    case audioControlsUnavailable(retryIntervalSeconds: Int)
    case waitingForAudioControls(secondsRemaining: Int)
    case monitoring(players: Int, newlyMuted: Int, newlyUnmuted: Int)
    case failed(String)

    var message: String {
        switch self {
        case .stopped:
            return "Ad muting stopped"
        case .scanning:
            return "Checking Chrome players…"
        case .waitingForPlayers:
            return "Ad muting — waiting for a Chrome player"
        case .waitingForPlayback:
            return "Ad muting — waiting for playback to resume"
        case let .audioControlsUnavailable(retryIntervalSeconds):
            return "Ad muting — audio controls unavailable; checking every \(retryIntervalSeconds)s"
        case let .waitingForAudioControls(secondsRemaining):
            return "Ad muting — waiting for audio controls (\(secondsRemaining)s left)"
        case let .monitoring(players, newlyMuted, newlyUnmuted):
            var changes: [String] = []
            if newlyMuted > 0 { changes.append("muted \(newlyMuted) ad\(newlyMuted == 1 ? "" : "s")") }
            if newlyUnmuted > 0 { changes.append("restored \(newlyUnmuted) player\(newlyUnmuted == 1 ? "" : "s")") }
            let suffix = changes.isEmpty ? "" : " — " + changes.joined(separator: ", ")
            return "Ad muting \(players) Chrome player\(players == 1 ? "" : "s")\(suffix)"
        case let .failed(message):
            return "Ad muting stopped: \(message)"
        }
    }
}

final class MonitorCancellation {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw MonitoringCancelled() }
    }
}

/// Owns opt-in polling, cancellation, run generations, and monitor status.
/// Public methods are called on the main thread; AX work runs serially elsewhere.
final class AdMonitor {
    typealias PlayerFactory = () throws -> PlayerControlling

    private let operationQueue: DispatchQueue
    private let interval: TimeInterval
    private let playerFactory: PlayerFactory
    private let audioAvailabilityTimeout: TimeInterval
    private let monotonicTime: () -> TimeInterval
    private let audioRetryInterval: TimeInterval
    private enum PassResult {
        case complete(players: Int, newlyMuted: Int, newlyUnmuted: Int)
        case waitingForAudio(remaining: TimeInterval)
        case waitingForPlayback
        case audioRetry
    }
    private final class RunContext {
        let player: PlayerControlling
        let policy = AdAudioPolicy()
        var audioUnavailableSince: TimeInterval?
        var isSlowAudioRetry = false

        init(player: PlayerControlling) { self.player = player }
    }

    /// Accessed only by operationQueue.
    private var operationRun: UInt64?
    /// Accessed only by operationQueue.
    private var operationContext: RunContext?
    private var generation: UInt64 = 0
    private var cancellation: MonitorCancellation?
    private var scheduledPass: DispatchWorkItem?

    private(set) var isRunning = false
    private(set) var status: AdMonitorStatus = .stopped
    var onStatusChange: ((AdMonitorStatus) -> Void)?

    init(
        operationQueue: DispatchQueue,
        interval: TimeInterval = 2.5,
        audioAvailabilityTimeout: TimeInterval = 30,
        audioRetryInterval: TimeInterval = 30,
        monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        playerFactory: @escaping PlayerFactory
    ) {
        self.operationQueue = operationQueue
        self.interval = interval
        precondition(audioAvailabilityTimeout.isFinite && audioAvailabilityTimeout > 0)
        precondition(audioRetryInterval.isFinite && audioRetryInterval > 0)
        self.audioRetryInterval = audioRetryInterval
        self.playerFactory = playerFactory
        self.audioAvailabilityTimeout = audioAvailabilityTimeout
        self.monotonicTime = monotonicTime
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }
        generation &+= 1
        let run = generation
        let token = MonitorCancellation()
        cancellation = token
        isRunning = true
        publish(.scanning)
        enqueuePass(run: run, token: token, delay: 0)
    }

    func stopAndDrain(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        isRunning = false
        cancellation?.cancel()
        cancellation = nil
        scheduledPass?.cancel()
        scheduledPass = nil
        publish(.stopped)

        // The queue is serial. This marker runs after any in-flight AX pass,
        // ensuring setup/quit cannot overtake a final cancellation check.
        operationQueue.async {
            self.operationRun = nil
            self.operationContext = nil
            DispatchQueue.main.async { completion?() }
        }
    }

    private func enqueuePass(run: UInt64, token: MonitorCancellation, delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.runPass(run: run, token: token)
        }
        scheduledPass = item
        if delay == 0 {
            operationQueue.async(execute: item)
        } else {
            operationQueue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func runPass(run: UInt64, token: MonitorCancellation) {
        do {
            try token.check()
            let context = try context(for: run)
            if !context.isSlowAudioRetry, let since = context.audioUnavailableSince,
               audioTimeRemaining(since: since) <= 0 {
                context.isSlowAudioRetry = true
                context.policy.interruptCompleteAbsenceScans()
                completePass(run: run, token: token, result: .audioRetry)
                return
            }
            let players: [PlayerState]
            do {
                players = try context.player.discoverPlayers()
            } catch is PlayerPlaybackPaused {
                try token.check()
                context.policy.interruptCompleteAbsenceScans()
                context.audioUnavailableSince = nil
                context.isSlowAudioRetry = false
                completePass(run: run, token: token, result: .waitingForPlayback)
                return
            } catch is ChromeAudioControlsUnavailable {
                // Only discovery can wait: no action or readback failure is replayed.
                try token.check()
                context.policy.interruptCompleteAbsenceScans()
                let since = context.audioUnavailableSince ?? monotonicTime()
                context.audioUnavailableSince = since
                let remaining = audioTimeRemaining(since: since)
                if context.isSlowAudioRetry || remaining <= 0 {
                    context.isSlowAudioRetry = true
                    completePass(run: run, token: token, result: .audioRetry)
                } else {
                    completePass(run: run, token: token, result: .waitingForAudio(remaining: remaining))
                }
                return
            }
            try token.check()
            if !context.isSlowAudioRetry, let since = context.audioUnavailableSince,
               audioTimeRemaining(since: since) <= 0 {
                context.isSlowAudioRetry = true
                context.policy.interruptCompleteAbsenceScans()
                completePass(run: run, token: token, result: .audioRetry)
                return
            }
            let expected = players.map(\.identity)
            let restoreCandidates = context.policy.restoreCandidates(afterCompleteScan: players)
            var newlyMuted = 0
            var newlyUnmuted = 0
            for player in players where player.hasAdMarker && !player.muted {
                try token.check()
                let outcome = try context.player.muteIfCurrentlyMarkedAd(
                    player.identity,
                    expectedPlayers: expected,
                    isCancelled: { token.isCancelled }
                )
                if outcome == .mutedAndVerified {
                    context.policy.claimAfterVerifiedMute(player.identity)
                    newlyMuted += 1
                }
            }
            for identity in restoreCandidates where context.policy.owns(identity) {
                try token.check()
                let outcome = try context.player.unmuteIfAdMarkerAbsent(
                    identity,
                    expectedPlayers: expected,
                    isCancelled: { token.isCancelled }
                )
                context.policy.recordRestore(outcome, for: identity)
                if outcome == .unmutedAndVerified { newlyUnmuted += 1 }
            }
            try token.check()
            context.audioUnavailableSince = nil
            context.isSlowAudioRetry = false
            DispatchQueue.main.async { [weak self] in
                self?.finishPass(
                    run: run,
                    token: token,
                    result: .success(.complete(players: players.count, newlyMuted: newlyMuted, newlyUnmuted: newlyUnmuted))
                )
            }
        } catch {
            discardContext(for: run)
            DispatchQueue.main.async { [weak self] in
                self?.finishPass(run: run, token: token, result: .failure(error))
            }
        }
    }

    private func completePass(run: UInt64, token: MonitorCancellation, result: PassResult) {
        DispatchQueue.main.async { [weak self] in
            self?.finishPass(run: run, token: token, result: .success(result))
        }
    }

    private func finishPass(
        run: UInt64,
        token: MonitorCancellation,
        result: Result<PassResult, Error>
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == run, isRunning, cancellation === token, !token.isCancelled else { return }
        switch result {
        case let .success(.complete(players, newlyMuted, newlyUnmuted)):
            publish(players == 0
                ? .waitingForPlayers
                : .monitoring(players: players, newlyMuted: newlyMuted, newlyUnmuted: newlyUnmuted))
            // Schedule only after the completed pass, so polls never overlap.
            enqueuePass(run: run, token: token, delay: interval)
        case .success(.waitingForPlayback):
            publish(.waitingForPlayback)
            enqueuePass(run: run, token: token, delay: interval)
        case .success(.audioRetry):
            publish(.audioControlsUnavailable(retryIntervalSeconds: Int(ceil(audioRetryInterval))))
            enqueuePass(run: run, token: token, delay: audioRetryInterval)
        case let .success(.waitingForAudio(remaining)):
            publish(.waitingForAudioControls(secondsRemaining: Int(ceil(remaining))))
            enqueuePass(run: run, token: token, delay: min(interval, remaining))
        case let .failure(error):
            isRunning = false
            cancellation = nil
            scheduledPass = nil
            publish(.failed(Self.actionableMessage(for: error)))
        }
    }

    private func audioTimeRemaining(since: TimeInterval) -> TimeInterval {
        audioAvailabilityTimeout - (monotonicTime() - since)
    }

    private func context(for run: UInt64) throws -> RunContext {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        if operationRun == run, let operationContext { return operationContext }
        let context = RunContext(player: try playerFactory())
        operationRun = run
        operationContext = context
        return context
    }

    private func discardContext(for run: UInt64) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard operationRun == run else { return }
        operationRun = nil
        operationContext = nil
    }

    private func publish(_ next: AdMonitorStatus) {
        status = next
        onStatusChange?(next)
    }

    private static func actionableMessage(for error: Error) -> String {
        if error is MonitoringCancelled { return "cancelled" }
        return String(describing: error)
    }
}
