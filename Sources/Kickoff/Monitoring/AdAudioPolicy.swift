import Foundation

/// Per-monitor-run ownership of tabs muted by this run. Claims never survive a
/// stop, restart, cancellation, setup, quit, or terminal error. A lease may
/// outlive a temporary gap in supported-player discovery, but cannot act then.
final class AdAudioPolicy {
    private struct Lease {
        var consecutiveCompleteAbsenceScans = 0
    }

    private var leases: [UUID: Lease] = [:]

    func claimAfterVerifiedMute(_ identity: PlayerIdentity) {
        leases[identity.token] = Lease()
    }

    func restoreCandidates(afterCompleteScan players: [PlayerState]) -> [PlayerIdentity] {
        var candidates: [PlayerIdentity] = []
        for player in players {
            let token = player.identity.token
            guard var lease = leases[token] else { continue }
            if !player.muted {
                leases.removeValue(forKey: token)
            } else if player.hasAdMarker {
                lease.consecutiveCompleteAbsenceScans = 0
                leases[token] = lease
            } else {
                lease.consecutiveCompleteAbsenceScans += 1
                leases[token] = lease
                if lease.consecutiveCompleteAbsenceScans >= 2 {
                    candidates.append(player.identity)
                }
            }
        }
        return candidates
    }

    /// An incomplete scan breaks absence evidence without relinquishing an owned mute.
    func interruptCompleteAbsenceScans() {
        for identity in leases.keys {
            leases[identity]?.consecutiveCompleteAbsenceScans = 0
        }
    }

    func recordRestore(_ outcome: UnmuteAfterAdOutcome, for identity: PlayerIdentity) {
        switch outcome {
        case .unmutedAndVerified, .alreadyUnmuted:
            leases.removeValue(forKey: identity.token)
        case .markerReappeared:
            guard var lease = leases[identity.token] else { return }
            lease.consecutiveCompleteAbsenceScans = 0
            leases[identity.token] = lease
        }
    }

    func owns(_ identity: PlayerIdentity) -> Bool { leases[identity.token] != nil }
}
