import Foundation

/// Per-monitor-run ownership of tabs muted by this run. Claims never survive a
/// stop, restart, cancellation, setup, quit, or error.
final class AdAudioPolicy {
    private struct Lease {
        var consecutiveCompleteAbsenceScans = 0
    }

    private var leases: [HuluPlayerIdentity: Lease] = [:]

    func claimAfterVerifiedMute(_ identity: HuluPlayerIdentity) {
        leases[identity] = Lease()
    }

    func restoreCandidates(afterCompleteScan players: [HuluPlayerState]) -> [HuluPlayerIdentity] {
        let current = Dictionary(uniqueKeysWithValues: players.map { ($0.identity, $0) })
        leases = leases.filter { current[$0.key] != nil }

        var candidates: [HuluPlayerIdentity] = []
        for player in players {
            guard var lease = leases[player.identity] else { continue }
            if !player.muted {
                leases.removeValue(forKey: player.identity)
            } else if player.hasAdMarker {
                lease.consecutiveCompleteAbsenceScans = 0
                leases[player.identity] = lease
            } else {
                lease.consecutiveCompleteAbsenceScans += 1
                leases[player.identity] = lease
                if lease.consecutiveCompleteAbsenceScans >= 2 {
                    candidates.append(player.identity)
                }
            }
        }
        return candidates
    }

    func recordRestore(_ outcome: UnmuteAfterAdOutcome, for identity: HuluPlayerIdentity) {
        switch outcome {
        case .unmutedAndVerified, .alreadyUnmuted:
            leases.removeValue(forKey: identity)
        case .markerReappeared:
            guard var lease = leases[identity] else { return }
            lease.consecutiveCompleteAbsenceScans = 0
            leases[identity] = lease
        }
    }

    func owns(_ identity: HuluPlayerIdentity) -> Bool { leases[identity] != nil }
}
