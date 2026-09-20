import AppKit
import ApplicationServices
import Foundation

/// Owns Hulu watch-player discovery and exact `__player__` Ad-marker checks.
/// ChromeTabAudioClient exclusively owns browser tab audio mutation/readback.
final class HuluPlayerClient: HuluPlayerControlling {
    private struct BoundPlayer {
        let identity: HuluPlayerIdentity
        let area: ChromeWatchArea
        let audio: ChromeTabAudioBinding
    }

    private struct LivePlayer {
        let bound: BoundPlayer
        let playerRoot: AXUIElement
        let adMarkers: [AXUIElement]
        var hasAdMarker: Bool { !adMarkers.isEmpty }
    }

    private let chrome: ChromeAccessibilityAccessing
    private let tabAudio: ChromeTabAudioClient
    private var bindings: [UUID: BoundPlayer] = [:]

    init(chrome: ChromeAccessibilityAccessing, readbackTimeout: TimeInterval = 2) {
        self.chrome = chrome
        tabAudio = ChromeTabAudioClient(chrome: chrome, readbackTimeout: readbackTimeout)
    }

    convenience init() throws { try self.init(chrome: ChromeAccessibilityClient()) }

    func discoverPlayers() throws -> [HuluPlayerState] {
        try retryInvalidRead {
            let areas = try currentWatchAreas()
            let audioBindings = try tabAudio.bind(areas)
            guard audioBindings.count == areas.count else {
                throw AccessibilityFailure("Chrome did not produce one native tab-audio binding per Hulu watch area.")
            }
            var next: [UUID: BoundPlayer] = [:]
            var result: [HuluPlayerState] = []
            for area in areas {
                guard let audio = uniqueAudioBinding(for: area, in: audioBindings) else {
                    throw AccessibilityFailure("A Hulu watch area did not map uniquely to a native Chrome tab.")
                }
                let identity = stableIdentity(for: area, audio: audio) ??
                    HuluPlayerIdentity(token: UUID(), url: area.url)
                let bound = BoundPlayer(identity: identity, area: area, audio: audio)
                let live = try readPlayer(bound)
                next[identity.token] = bound
                result.append(state(live))
            }
            bindings = next
            return result
        }
    }

    func unmuteIfAdMarkerAbsent(
        _ player: HuluPlayerIdentity,
        expectedPlayers: [HuluPlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> UnmuteAfterAdOutcome {
        if isCancelled() { throw MonitoringCancelled() }
        let live = try retryInvalidRead { try resolve(player, expectedPlayers: expectedPlayers) }
        if live.hasAdMarker { return .markerReappeared }

        let observed = try tabAudio.immediateState(of: live.bound.audio, validateAction: false)
        guard observed == .muted else { return .alreadyUnmuted }
        let prepared = try tabAudio.immediateState(of: live.bound.audio, validateAction: true)
        guard prepared == .muted else { return .alreadyUnmuted }

        // Absence is established only by a new, complete player-scoped scan.
        // No tree traversal may occur between this proof and the press.
        let fresh = try readPlayer(live.bound)
        if fresh.hasAdMarker { return .markerReappeared }
        let immediate = try tabAudio.finalDirectState(of: fresh.bound.audio)
        guard immediate == .muted else { return .alreadyUnmuted }
        if isCancelled() { throw MonitoringCancelled() }

        let result = tabAudio.pressOnce(fresh.bound.audio)
        _ = try tabAudio.waitForState(.playing, binding: fresh.bound.audio, pressResult: result, isCancelled: isCancelled)
        return .unmutedAndVerified
    }

    func muteIfCurrentlyMarkedAd(
        _ player: HuluPlayerIdentity,
        expectedPlayers: [HuluPlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> MuteMarkedAdOutcome {
        if isCancelled() { throw MonitoringCancelled() }
        let live = try retryInvalidRead { try resolve(player, expectedPlayers: expectedPlayers) }
        guard live.hasAdMarker else { return .markerDisappeared }
        guard live.bound.audio.state != .muted else { return .alreadyMuted }

        let prepared = try tabAudio.immediateState(of: live.bound.audio, validateAction: true)
        guard prepared != .muted else { return .alreadyMuted }
        guard try markerIsStillPresent(in: live) else { return .markerDisappeared }
        let immediate = try tabAudio.finalDirectState(of: live.bound.audio)
        guard immediate != .muted else { return .alreadyMuted }
        if isCancelled() { throw MonitoringCancelled() }

        let result = tabAudio.pressOnce(live.bound.audio)
        _ = try tabAudio.waitForState(.muted, binding: live.bound.audio, pressResult: result, isCancelled: isCancelled)
        return .mutedAndVerified
    }

    func discoveryReport() throws -> [[String: Any]] { try discoverPlayers().map(\.summary) }

    func listen(to targetURL: String) throws -> [String: Any] {
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedBefore = try chrome.attribute(chrome.application, kAXFocusedWindowAttribute)
        var players = try discoverPlayers()
        let expected = players.map(\.identity)
        guard players.count == 2,
              players.filter({ $0.identity.url == targetURL }).count == 1,
              let target = players.first(where: { $0.identity.url == targetURL }),
              let source = players.first(where: { $0.identity.token != target.identity.token }),
              let targetBinding = bindings[target.identity.token],
              let sourceBinding = bindings[source.identity.token],
              !CFEqual(targetBinding.area.window, sourceBinding.area.window) else {
            throw AccessibilityFailure("Expected exactly two separate Hulu player windows and one matching target watch URL.")
        }

        var actions: [[String: Any]] = []
        if !source.muted, let result = try setMuted(true, for: source.identity, expectedPlayers: expected, requireOtherMuted: nil) {
            actions.append(["url": source.identity.url, "action": "mute", "axResult": result.rawValue, "verified": true])
        }
        let sourceNow = try resolve(source.identity, expectedPlayers: expected)
        guard try tabAudio.immediateState(of: sourceNow.bound.audio, validateAction: false) == .muted else {
            throw AccessibilityFailure("The other Chrome tab is not verified muted; refusing to unmute the target.")
        }
        if target.muted, let result = try setMuted(false, for: target.identity, expectedPlayers: expected, requireOtherMuted: source.identity) {
            actions.append(["url": target.identity.url, "action": "unmute", "axResult": result.rawValue, "verified": true])
        }
        players = try expected.map { state(try resolve($0, expectedPlayers: expected)) }
        guard players.allSatisfy({ $0.muted == ($0.identity.token != target.identity.token) }) else {
            throw AccessibilityFailure("Final Chrome tab-audio verification failed; inspect both players before continuing.")
        }
        let focusedAfter = try chrome.attribute(chrome.application, kAXFocusedWindowAttribute)
        let focusUnchanged: Bool
        switch (focusedBefore, focusedAfter) {
        case (nil, nil): focusUnchanged = true
        case let (before?, after?): focusUnchanged = CFEqual(before, after)
        default: focusUnchanged = false
        }
        return [
            "chromePID": chrome.pid,
            "actions": actions,
            "players": players.map(\.summary),
            "frontmostApplicationUnchanged": frontmostBefore == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            "focusedChromeWindowUnchanged": focusUnchanged,
        ]
    }

    private func setMuted(
        _ desired: Bool,
        for identity: HuluPlayerIdentity,
        expectedPlayers: [HuluPlayerIdentity],
        requireOtherMuted: HuluPlayerIdentity?
    ) throws -> AXError? {
        let live = try resolve(identity, expectedPlayers: expectedPlayers)
        let desiredState: ChromeTabAudioState = desired ? .muted : .playing
        if try tabAudio.immediateState(of: live.bound.audio, validateAction: false) == desiredState { return nil }
        if let other = requireOtherMuted {
            let otherLive = try resolve(other, expectedPlayers: expectedPlayers)
            guard try tabAudio.immediateState(of: otherLive.bound.audio, validateAction: false) == .muted else {
                throw AccessibilityFailure("The other Chrome tab became unmuted; refusing to unmute the target.")
            }
        }
        if try tabAudio.immediateState(of: live.bound.audio, validateAction: true) == desiredState { return nil }
        let result = tabAudio.pressOnce(live.bound.audio)
        _ = try tabAudio.waitForState(desiredState, binding: live.bound.audio, pressResult: result, isCancelled: { false })
        return result
    }

    private func resolve(_ identity: HuluPlayerIdentity, expectedPlayers: [HuluPlayerIdentity]) throws -> LivePlayer {
        guard let target = bindings[identity.token], target.identity == identity,
              expectedPlayers.count == bindings.count,
              expectedPlayers.allSatisfy({ bindings[$0.token] != nil }) else {
            throw AccessibilityFailure("The current Ad Muting pass no longer owns this Hulu player identity.")
        }
        let areas = try currentWatchAreas()
        guard areas.count == expectedPlayers.count,
              expectedPlayers.allSatisfy({ expected in
                  guard let bound = bindings[expected.token] else { return false }
                  return areas.filter { sameArea($0, bound.area) }.count == 1
              }),
              let targetArea = areas.first(where: { sameArea($0, target.area) }) else {
            throw AccessibilityFailure("A Chrome window, Hulu web area, or watch URL changed during the Ad Muting pass. Ad Muting stopped before another press.")
        }
        let audioBindings = try tabAudio.bind(areas)
        guard let currentAudio = uniqueAudioBinding(for: targetArea, in: audioBindings),
              CFEqual(currentAudio.tab, target.audio.tab),
              CFEqual(currentAudio.button, target.audio.button) else {
            throw AccessibilityFailure("The native Chrome tab-audio identity changed during the Ad Muting pass.")
        }
        return try readPlayer(BoundPlayer(identity: identity, area: targetArea, audio: currentAudio))
    }

    private func state(_ live: LivePlayer) -> HuluPlayerState {
        HuluPlayerState(
            identity: live.bound.identity,
            windowIndex: live.bound.area.windowIndex,
            muted: live.bound.audio.state == .muted,
            audioDescription: live.bound.audio.state.description,
            hasAdMarker: live.hasAdMarker
        )
    }

    private func readPlayer(_ bound: BoundPlayer) throws -> LivePlayer {
        let roots = try chrome.inspect(
            bound.area.webArea,
            maximumNodes: 1_500,
            maximumDepth: 45,
            timeout: 5,
            stopDescending: { ($0.depth > 0 && $0.role == "AXWebArea") || $0.domIdentifier == "__player__" }
        ).filter { $0.domIdentifier == "__player__" && !$0.hidden }
        guard roots.count == 1, let root = roots.first else {
            throw AccessibilityFailure("Hulu watch page \(bound.identity.url) does not expose one visible __player__ container.")
        }
        let nodes = try chrome.inspect(root.element, maximumNodes: 1_200, maximumDepth: 35, timeout: 4, stopDescending: { _ in false })
        let markers = nodes.filter {
            !$0.hidden && $0.role == kAXStaticTextRole && AdMarker.matches($0.value)
        }.map(\.element)
        return LivePlayer(bound: bound, playerRoot: root.element, adMarkers: markers)
    }

    private func markerIsStillPresent(in live: LivePlayer) throws -> Bool {
        guard try chrome.attribute(live.playerRoot, "AXHidden") as? Bool != true else { return false }
        return try live.adMarkers.contains { marker in
            try chrome.text(marker, kAXRoleAttribute) == kAXStaticTextRole &&
                chrome.attribute(marker, "AXHidden") as? Bool != true &&
                AdMarker.matches(try chrome.text(marker, kAXValueAttribute))
        }
    }

    private func currentWatchAreas() throws -> [ChromeWatchArea] {
        var result: [ChromeWatchArea] = []
        for (index, window) in try chrome.windows().enumerated() {
            if try chrome.isMinimized(window) { continue }
            let nodes = try chrome.inspect(window, maximumNodes: 1_500, maximumDepth: 30, timeout: 5, stopDescending: { $0.role == "AXWebArea" })
            let webAreas = nodes.filter { $0.role == "AXWebArea" && !$0.hidden }
            guard let topDepth = webAreas.map(\.depth).min() else { continue }
            for node in webAreas where node.depth == topDepth {
                guard let url = node.url, Self.isHuluWatchURL(url) else { continue }
                result.append(ChromeWatchArea(
                    window: window,
                    windowIndex: index,
                    webArea: node.element,
                    url: url,
                    title: node.title,
                    visibleAreaCountInWindow: webAreas.filter { $0.depth == topDepth }.count
                ))
            }
        }
        return result
    }

    private func retryInvalidRead<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement { return try operation() }
    }

    private func uniqueAudioBinding(for area: ChromeWatchArea, in candidates: [ChromeTabAudioBinding]) -> ChromeTabAudioBinding? {
        let matches = candidates.filter {
            $0.url == area.url && CFEqual($0.window, area.window) && CFEqual($0.webArea, area.webArea)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func sameArea(_ lhs: ChromeWatchArea, _ rhs: ChromeWatchArea) -> Bool {
        lhs.url == rhs.url && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.webArea, rhs.webArea)
    }

    private func stableIdentity(
        for area: ChromeWatchArea,
        audio: ChromeTabAudioBinding
    ) -> HuluPlayerIdentity? {
        let matches = bindings.values.filter {
            sameArea($0.area, area) &&
                CFEqual($0.audio.tab, audio.tab) &&
                CFEqual($0.audio.button, audio.button)
        }
        return matches.count == 1 ? matches[0].identity : nil
    }

    static func isHuluWatchURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https",
              ["hulu.com", "www.hulu.com"].contains(url.host ?? "") else { return false }
        return url.path.hasPrefix("/watch/")
    }
}
