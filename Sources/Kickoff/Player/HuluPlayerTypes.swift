import Foundation

struct HuluPlayerIdentity: Hashable {
    let token: UUID
    let url: String
}

struct HuluPlayerState: Equatable {
    let identity: HuluPlayerIdentity
    let windowIndex: Int
    let muted: Bool
    let audioDescription: String
    let hasAdMarker: Bool

    var summary: [String: Any] {
        [
            "windowIndex": windowIndex,
            "url": identity.url,
            "muted": muted,
            "audioDescription": audioDescription,
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

protocol HuluPlayerControlling: AnyObject {
    func discoverPlayers() throws -> [HuluPlayerState]
    func muteIfCurrentlyMarkedAd(
        _ player: HuluPlayerIdentity,
        expectedPlayers: [HuluPlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> MuteMarkedAdOutcome
    func unmuteIfAdMarkerAbsent(
        _ player: HuluPlayerIdentity,
        expectedPlayers: [HuluPlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> UnmuteAfterAdOutcome
}

enum AdMarker {
    private static let expression = try! NSRegularExpression(pattern: #"^Ad(?: [0-9]+:[0-5][0-9])?$"#)

    static func matches(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    static func isPresent(inPlayerNodes nodes: [PlayerContentNode]) -> Bool {
        nodes.contains { $0.role == "AXStaticText" && matches($0.value) }
    }
}

struct MonitoringCancelled: Error {}
