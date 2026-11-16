import AppKit
import ApplicationServices
import Foundation

/// Owns supported Chrome player discovery and exact provider-scoped evidence.
/// ChromeTabAudioClient exclusively owns browser tab audio mutation/readback.
final class ChromePlayerClient: PlayerControlling {
    private struct BoundPlayer {
        let identity: PlayerIdentity
        let area: ChromeWatchArea
        let tab: AXUIElement
        let audio: ChromeTabAudioAvailability
    }

    private struct LivePlayer {
        let bound: BoundPlayer
        let provider: PlayerAdDetection
        let evidence: PlayerAdDetection.Evidence
        var hasAdMarker: Bool { !evidence.markers.isEmpty }
    }

    private struct ControllablePlayer {
        let live: LivePlayer
        let audio: ChromeTabAudioBinding
    }

    private let chrome: ChromeAccessibilityAccessing
    private let tabAudio: ChromeTabAudioClient
    private var bindings: [UUID: BoundPlayer] = [:]
    private var activeTokens: Set<UUID> = []

    init(chrome: ChromeAccessibilityAccessing, readbackTimeout: TimeInterval = 2) {
        self.chrome = chrome
        tabAudio = ChromeTabAudioClient(chrome: chrome, readbackTimeout: readbackTimeout)
    }

    convenience init() throws { try self.init(chrome: ChromeAccessibilityClient()) }

    func discoverPlayers() throws -> [PlayerState] {
        try retryInvalidRead {
            let areas = try currentWatchAreas()
            let panes = try tabAudio.bind(areas)
            guard panes.count == areas.count else {
                throw AccessibilityFailure("Chrome did not produce one native tab-audio binding per supported watch area.")
            }
            if let unavailable = noControlsOnAnyPane(panes) {
                // Every unavailable area must carry complete, scoped pause evidence.
                // Binding conflicts are validated before this recoverable classification.
                if try unavailable.watchAreas.allSatisfy({ area in
                    guard let provider = PlayerAdDetection.provider(for: area.url) else { return false }
                    return try provider.isPlaybackPaused(in: area.webArea, url: area.url, chrome: chrome)
                }) {
                    throw PlayerPlaybackPaused()
                }
                throw unavailable
            }
            var next: [UUID: BoundPlayer] = [:]
            var result: [PlayerState] = []
            for area in areas {
                guard let pane = uniquePane(for: area, in: panes) else {
                    throw AccessibilityFailure("A supported watch area did not map uniquely to a native Chrome tab.")
                }
                let identity = stableIdentity(for: area, tab: pane.tab) ??
                    PlayerIdentity(token: UUID(), url: area.url)
                let bound = BoundPlayer(identity: identity, area: area, tab: pane.tab, audio: pane.audio)
                let discovered = try discoveredState(bound)
                next[identity.token] = bound
                result.append(discovered)
            }
            // Keep tab references across a temporary gap in supported playback.
            // Only active bindings may authorize an audio action.
            bindings.merge(next) { _, current in current }
            activeTokens = Set(next.keys)
            return result
        }
    }

    func unmuteIfAdMarkerAbsent(
        _ player: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> UnmuteAfterAdOutcome {
        if isCancelled() { throw MonitoringCancelled() }
        let controllable = try retryInvalidRead { try resolve(player, expectedPlayers: expectedPlayers) }
        if controllable.live.hasAdMarker { return .markerReappeared }

        let observed = try tabAudio.immediateState(of: controllable.audio, validateAction: false)
        guard observed == .muted else { return .alreadyUnmuted }
        let prepared = try tabAudio.immediateState(of: controllable.audio, validateAction: true)
        guard prepared == .muted else { return .alreadyUnmuted }

        // Absence is established only by a new, complete player-scoped scan.
        // No tree traversal may occur between this proof and the press.
        let fresh = try readPlayer(controllable.live.bound)
        if fresh.hasAdMarker { return .markerReappeared }
        let immediate = try tabAudio.finalDirectState(of: controllable.audio)
        guard immediate == .muted else { return .alreadyUnmuted }
        if isCancelled() { throw MonitoringCancelled() }

        let result = tabAudio.pressOnce(controllable.audio)
        _ = try tabAudio.waitForState(.playing, binding: controllable.audio, pressResult: result, isCancelled: isCancelled)
        return .unmutedAndVerified
    }

    func muteIfCurrentlyMarkedAd(
        _ player: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        isCancelled: () -> Bool
    ) throws -> MuteMarkedAdOutcome {
        if isCancelled() { throw MonitoringCancelled() }
        let controllable = try retryInvalidRead { try resolve(player, expectedPlayers: expectedPlayers) }
        guard controllable.live.hasAdMarker else { return .markerDisappeared }
        guard controllable.audio.state != .muted else { return .alreadyMuted }

        let prepared = try tabAudio.immediateState(of: controllable.audio, validateAction: true)
        guard prepared != .muted else { return .alreadyMuted }
        guard try markerIsStillPresent(in: controllable.live) else { return .markerDisappeared }
        let immediate = try tabAudio.finalDirectState(of: controllable.audio)
        guard immediate != .muted else { return .alreadyMuted }
        if isCancelled() { throw MonitoringCancelled() }

        let result = tabAudio.pressOnce(controllable.audio)
        _ = try tabAudio.waitForState(.muted, binding: controllable.audio, pressResult: result, isCancelled: isCancelled)
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
            throw AccessibilityFailure("Expected exactly two separate Chrome player windows and one matching target watch URL.")
        }
        if let silent = players.first(where: { !$0.hasAudioControls }) {
            throw AccessibilityFailure("Listening requires Chrome tab audio controls on both players, but \(silent.identity.url) has none. \(silent.audio.description)")
        }

        var actions: [[String: Any]] = []
        if source.audio != .muted, let result = try setMuted(true, for: source.identity, expectedPlayers: expected, requireOtherMuted: nil) {
            actions.append(["url": source.identity.url, "action": "mute", "axResult": result.rawValue, "verified": true])
        }
        let sourceNow = try resolve(source.identity, expectedPlayers: expected)
        guard try tabAudio.immediateState(of: sourceNow.audio, validateAction: false) == .muted else {
            throw AccessibilityFailure("The other Chrome tab is not verified muted; refusing to unmute the target.")
        }
        if target.audio == .muted, let result = try setMuted(false, for: target.identity, expectedPlayers: expected, requireOtherMuted: source.identity) {
            actions.append(["url": target.identity.url, "action": "unmute", "axResult": result.rawValue, "verified": true])
        }
        players = try expected.map { state(try resolve($0, expectedPlayers: expected).live) }
        guard players.allSatisfy({ $0.audio == ($0.identity.token == target.identity.token ? .playing : .muted) }) else {
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
        for identity: PlayerIdentity,
        expectedPlayers: [PlayerIdentity],
        requireOtherMuted: PlayerIdentity?
    ) throws -> AXError? {
        let live = try resolve(identity, expectedPlayers: expectedPlayers)
        let desiredState: ChromeTabAudioState = desired ? .muted : .playing
        if try tabAudio.immediateState(of: live.audio, validateAction: false) == desiredState { return nil }
        if let other = requireOtherMuted {
            let otherLive = try resolve(other, expectedPlayers: expectedPlayers)
            guard try tabAudio.immediateState(of: otherLive.audio, validateAction: false) == .muted else {
                throw AccessibilityFailure("The other Chrome tab became unmuted; refusing to unmute the target.")
            }
        }
        if try tabAudio.immediateState(of: live.audio, validateAction: true) == desiredState { return nil }
        let result = tabAudio.pressOnce(live.audio)
        _ = try tabAudio.waitForState(desiredState, binding: live.audio, pressResult: result, isCancelled: { false })
        return result
    }

    private func resolve(_ identity: PlayerIdentity, expectedPlayers: [PlayerIdentity]) throws -> ControllablePlayer {
        guard let target = bindings[identity.token], activeTokens.contains(identity.token),
              target.identity == identity,
              expectedPlayers.count == activeTokens.count,
              expectedPlayers.allSatisfy({ activeTokens.contains($0.token) && bindings[$0.token]?.identity == $0 }) else {
            throw AccessibilityFailure("The current Ad Muting pass no longer owns this Chrome player identity.")
        }
        guard case let .controls(boundAudio) = target.audio else {
            throw AccessibilityFailure("This Chrome player had no native tab audio controls when it was discovered; it cannot be pressed.")
        }
        let areas = try currentWatchAreas()
        guard areas.count == expectedPlayers.count,
              expectedPlayers.allSatisfy({ expected in
                  guard let bound = bindings[expected.token] else { return false }
                  return areas.filter { sameArea($0, bound.area) }.count == 1
              }),
              let targetArea = areas.first(where: { sameArea($0, target.area) }) else {
            throw AccessibilityFailure("A Chrome window, supported web area, or watch URL changed during the Ad Muting pass. Ad Muting stopped before another press.")
        }
        let panes = try tabAudio.bind(areas)
        guard let currentPane = uniquePane(for: targetArea, in: panes), CFEqual(currentPane.tab, target.tab) else {
            throw AccessibilityFailure("The native Chrome tab-audio identity changed during the Ad Muting pass.")
        }
        if let gap = currentPane.controlsGap { throw gap }
        guard case let .controls(currentAudio) = currentPane.audio, CFEqual(currentAudio.button, boundAudio.button) else {
            throw AccessibilityFailure("The native Chrome tab-audio identity changed during the Ad Muting pass.")
        }
        let live = try readPlayer(BoundPlayer(identity: identity, area: targetArea, tab: currentPane.tab, audio: currentPane.audio))
        return ControllablePlayer(live: live, audio: currentAudio)
    }

    private func discoveredState(_ bound: BoundPlayer) throws -> PlayerState {
        do {
            return state(try readPlayer(bound))
        } catch let failure as AccessibilityFailure where failure.axError != .invalidUIElement {
            guard case let .unavailable(gap) = bound.audio else { throw failure }
            return PlayerState(
                identity: bound.identity,
                windowIndex: bound.area.windowIndex,
                audio: .noControls(reason: "\(gap.description) Player evidence unavailable: \(failure.description)"),
                hasAdMarker: false
            )
        }
    }

    private func state(_ live: LivePlayer) -> PlayerState {
        PlayerState(
            identity: live.bound.identity,
            windowIndex: live.bound.area.windowIndex,
            audio: playerAudio(live.bound.audio),
            hasAdMarker: live.hasAdMarker
        )
    }

    private func playerAudio(_ availability: ChromeTabAudioAvailability) -> PlayerAudio {
        switch availability {
        case let .controls(binding):
            return binding.state == .muted ? .muted : .playing
        case let .unavailable(gap):
            return .noControls(reason: gap.description)
        }
    }

    private func noControlsOnAnyPane(_ panes: [ChromeTabAudioPane]) -> ChromeAudioControlsUnavailable? {
        let gaps = panes.compactMap(\.controlsGap)
        guard let first = gaps.first, gaps.count == panes.count else { return nil }
        return gaps.dropFirst().reduce(first) { $0.merging($1) }
    }

    private func readPlayer(_ bound: BoundPlayer) throws -> LivePlayer {
        guard let provider = PlayerAdDetection.provider(for: bound.identity.url) else {
            throw AccessibilityFailure("Player URL is no longer a supported playback route.")
        }
        return LivePlayer(bound: bound, provider: provider, evidence: try provider.read(in: bound.area.webArea, chrome: chrome))
    }

    private func markerIsStillPresent(in live: LivePlayer) throws -> Bool {
        try live.provider.markerIsStillPresent(live.evidence, chrome: chrome)
    }

    private func currentWatchAreas() throws -> [ChromeWatchArea] {
        var result: [ChromeWatchArea] = []
        for (index, window) in try chrome.windows().enumerated() {
            if try chrome.isMinimized(window) { continue }
            let nodes = try chrome.inspect(window, maximumNodes: 1_500, maximumDepth: 30, timeout: 5, stopDescending: { $0.role == "AXWebArea" })
            let webAreas = nodes.filter { $0.role == "AXWebArea" && !$0.hidden && !Self.isDockedDevTools($0) }
            guard let topDepth = webAreas.map(\.depth).min() else { continue }
            let visible = webAreas.filter { $0.depth == topDepth }
            let unsupported = visible.filter { node in
                node.url.flatMap(PlayerAdDetection.provider(for:)) == nil
            }
            for node in visible {
                guard let url = node.url, PlayerAdDetection.provider(for: url) != nil else { continue }
                result.append(ChromeWatchArea(
                    window: window,
                    windowIndex: index,
                    webArea: node.element,
                    url: url,
                    title: node.title,
                    visibleAreaCountInWindow: visible.count,
                    unsupportedVisiblePeerWebArea: visible.count == 2 && unsupported.count == 1 ? unsupported[0].element : nil
                ))
            }
        }
        return result
    }

    private static func isDockedDevTools(_ node: AccessibilityNode) -> Bool {
        node.url.flatMap(URL.init(string:))?.scheme == "devtools"
    }

    private func retryInvalidRead<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let failure as AccessibilityFailure where failure.axError == .invalidUIElement { return try operation() }
    }

    private func uniquePane(for area: ChromeWatchArea, in panes: [ChromeTabAudioPane]) -> ChromeTabAudioPane? {
        let matches = panes.filter { sameArea($0.area, area) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func sameArea(_ lhs: ChromeWatchArea, _ rhs: ChromeWatchArea) -> Bool {
        lhs.url == rhs.url && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.webArea, rhs.webArea)
    }

    private func stableIdentity(
        for area: ChromeWatchArea,
        tab: AXUIElement
    ) -> PlayerIdentity? {
        // The native tab can persist when playback replaces its page or audio button.
        let matches = bindings.values.filter {
            CFEqual($0.area.window, area.window) && CFEqual($0.tab, tab)
        }
        guard matches.count == 1 else { return nil }
        return PlayerIdentity(token: matches[0].identity.token, url: area.url)
    }

}
