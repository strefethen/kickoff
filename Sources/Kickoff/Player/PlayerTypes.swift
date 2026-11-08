import Foundation

struct PlayerIdentity: Hashable {
    let token: UUID
    let url: String
}

enum PlayerAudio: Equatable {
    case playing
    case muted
    case noControls(reason: String)

    var description: String {
        switch self {
        case .playing: return ChromeTabAudioState.playing.description
        case .muted: return ChromeTabAudioState.muted.description
        case let .noControls(reason): return "No Chrome tab audio controls: \(reason)"
        }
    }
}

struct PlayerState: Equatable {
    let identity: PlayerIdentity
    let windowIndex: Int
    let audio: PlayerAudio
    let hasAdMarker: Bool

    var hasAudioControls: Bool {
        if case .noControls = audio { return false }
        return true
    }

    var summary: [String: Any] {
        [
            "windowIndex": windowIndex,
            "url": identity.url,
            "muted": hasAudioControls ? (audio == .muted) as Any : NSNull(),
            "tabAudioControls": hasAudioControls ? "available" : "unavailable",
            "audioDescription": audio.description,
            "adState": hasAdMarker ? "marked-ad" : "unknown",
        ]
    }
}

enum MuteMarkedAdOutcome: Equatable {
    case mutedAndVerified
    case alreadyMuted
    case markerDisappeared
}

enum UnmuteAfterAdOutcome: Equatable {
    case unmutedAndVerified
    case alreadyUnmuted
    case markerReappeared
}

protocol PlayerControlling: AnyObject {
    func discoverPlayers() throws -> [PlayerState]
    func muteIfCurrentlyMarkedAd(
        _ player: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> MuteMarkedAdOutcome
    func unmuteIfAdMarkerAbsent(
        _ player: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> UnmuteAfterAdOutcome
}

enum AdMarker {
    static func matches(_ value: String) -> Bool {
        value.range(of: "ad", options: [.anchored, .caseInsensitive]) != nil
    }

    static func isPresent(inPlayerNodes nodes: [PlayerContentNode]) -> Bool {
        nodes.contains { $0.role == "AXStaticText" && matches($0.value) }
    }
}

/// Complete discovery identified paused playback, so tab audio is not required yet.
struct PlayerPlaybackPaused: Error, CustomStringConvertible {
    var description: String { "Supported playback is paused; waiting for playback to resume." }
}

struct MonitoringCancelled: Error {}
