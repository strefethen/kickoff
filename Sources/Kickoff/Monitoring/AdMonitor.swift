import Foundation

enum AdMonitorStatus: Equatable {
    case stopped
    case scanning
    case waitingForPlayers
    case monitoring(players: Int, newlyMuted: Int, newlyUnmuted: Int)
    case failed(String)

    var message: String {
        switch self {
        case .stopped:
            return "Ad muting stopped"
        case .scanning:
            return "Checking Hulu players…"
        case .waitingForPlayers:
            return "Ad muting — waiting for a Hulu player"
        case let .monitoring(players, newlyMuted, newlyUnmuted):
            var changes: [String] = []
            if newlyMuted > 0 { changes.append("muted \(newlyMuted) ad\(newlyMuted == 1 ? "" : "s")") }
            if newlyUnmuted > 0 { changes.append("restored \(newlyUnmuted) player\(newlyUnmuted == 1 ? "" : "s")") }
            let suffix = changes.isEmpty ? "" : " — " + changes.joined(separator: ", ")
            return "Ad muting \(players) Hulu player\(players == 1 ? "" : "s")\(suffix)"
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
    typealias PlayerFactory = () throws -> HuluPlayerControlling

    private let operationQueue: DispatchQueue
    private let interval: TimeInterval
    private let playerFactory: PlayerFactory
    private final class RunContext {
        let player: HuluPlayerControlling
        let policy = AdAudioPolicy()

        init(player: HuluPlayerControlling) { self.player = player }
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
        playerFactory: @escaping PlayerFactory
    ) {
        self.operationQueue = operationQueue
        self.interval = interval
        self.playerFactory = playerFactory
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
            let players = try context.player.discoverPlayers()
            try token.check()
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
            DispatchQueue.main.async { [weak self] in
                self?.finishPass(
                    run: run,
                    token: token,
                    result: .success((players.count, newlyMuted, newlyUnmuted))
                )
            }
        } catch {
            discardContext(for: run)
            DispatchQueue.main.async { [weak self] in
                self?.finishPass(run: run, token: token, result: .failure(error))
            }
        }
    }

    private func finishPass(
        run: UInt64,
        token: MonitorCancellation,
        result: Result<(players: Int, newlyMuted: Int, newlyUnmuted: Int), Error>
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == run, isRunning, cancellation === token, !token.isCancelled else { return }
        switch result {
        case let .success(summary):
            publish(summary.players == 0
                ? .waitingForPlayers
                : .monitoring(
                    players: summary.players,
                    newlyMuted: summary.newlyMuted,
                    newlyUnmuted: summary.newlyUnmuted
                ))
            // Schedule only after the completed pass, so polls never overlap.
            enqueuePass(run: run, token: token, delay: interval)
        case let .failure(error):
            isRunning = false
            cancellation = nil
            scheduledPass = nil
            publish(.failed(Self.actionableMessage(for: error)))
        }
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
