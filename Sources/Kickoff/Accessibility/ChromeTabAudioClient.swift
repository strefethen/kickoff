import ApplicationServices
import Foundation

enum ChromeTabAudioState: Equatable {
    case playing
    case muted

    var description: String {
        switch self {
        case .playing: return "Chrome tab audio playing"
        case .muted: return "Chrome tab audio muted"
        }
    }
}

struct ChromeWatchArea {
    let window: AXUIElement
    let windowIndex: Int
    let webArea: AXUIElement
    let url: String
    let title: String
    let visibleAreaCountInWindow: Int
}

struct ChromeTabAudioBinding {
    let window: AXUIElement
    let webArea: AXUIElement
    let url: String
    let tab: AXUIElement
    let button: AXUIElement
    let state: ChromeTabAudioState
    let webAreaTitle: String
    let viewCount: Int
    let splitSide: String?
    let peerWebArea: AXUIElement?
    let peerTab: AXUIElement?
}

/// Binds visible Chrome page areas to native tab-strip controls and owns the
/// browser-level audio mutation/readback contract.
final class ChromeTabAudioClient {
    private enum SplitSide: Hashable { case left, right }
    private struct AudioStatePending: Error {}

    private struct TabCandidate {
        let element: AXUIElement
        let button: AXUIElement?
        let title: String
        let nodeDescription: String
        let side: SplitSide?
        let selected: Bool
    }

    private let chrome: ChromeAccessibilityAccessing
    private let readbackTimeout: TimeInterval

    init(chrome: ChromeAccessibilityAccessing, readbackTimeout: TimeInterval = 2) {
        self.chrome = chrome
        self.readbackTimeout = readbackTimeout
    }

    func bind(_ watchAreas: [ChromeWatchArea]) throws -> [ChromeTabAudioBinding] {
        var result: [ChromeTabAudioBinding] = []
        var remaining = watchAreas
        while let first = remaining.first {
            let inWindow = remaining.filter { CFEqual($0.window, first.window) }
            remaining.removeAll { CFEqual($0.window, first.window) }
            result.append(contentsOf: try bind(inWindow, window: first.window))
        }
        return result
    }

    func immediateState(
        of binding: ChromeTabAudioBinding,
        validateAction: Bool
    ) throws -> ChromeTabAudioState {
        do {
            return try checkedState(of: binding, validateAction: validateAction, validateMapping: true)
        } catch is AudioStatePending {
            throw AccessibilityFailure("Chrome native tab has missing, conflicting, or changing Audio playing/Audio muted state.")
        }
    }

    /// Final bounded reads after marker validation. All native-tree traversal
    /// and split mapping validation must already have completed.
    func finalDirectState(of binding: ChromeTabAudioBinding) throws -> ChromeTabAudioState {
        do {
            return try checkedState(of: binding, validateAction: false, validateMapping: false)
        } catch is AudioStatePending {
            throw AccessibilityFailure("Chrome native tab has missing, conflicting, or changing Audio playing/Audio muted state.")
        }
    }

    private func checkedState(
        of binding: ChromeTabAudioBinding,
        validateAction: Bool,
        validateMapping: Bool
    ) throws -> ChromeTabAudioState {
        guard try chrome.windows().contains(where: { CFEqual($0, binding.window) }),
              try !chrome.isMinimized(binding.window),
              try currentURL(of: binding.webArea) == binding.url,
              try chrome.attribute(binding.webArea, "AXHidden") as? Bool != true,
              titleMatches(try chrome.text(binding.tab, kAXTitleAttribute), webAreaTitle: binding.webAreaTitle) else {
            throw AccessibilityFailure("The bound Chrome window or Hulu web area changed immediately before tab audio action.")
        }
        let parent = try chrome.attribute(binding.button, kAXParentAttribute)
        guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(),
              CFEqual(parent, binding.tab),
              try chrome.text(binding.button, kAXRoleAttribute) == kAXButtonRole,
              ["Mute tab", "Unmute tab"].contains(try chrome.text(binding.button, kAXTitleAttribute)) else {
            throw AccessibilityFailure("Chrome's bound tab audio button changed immediately before action.")
        }
        try validateDirectSelection(binding)
        if validateMapping { try validateCurrentMapping(binding) }
        if validateAction {
            guard try chrome.attribute(binding.button, kAXEnabledAttribute) as? Bool == true else {
                throw AccessibilityFailure("Chrome's tab audio button is disabled. Set chrome://flags/#enable-tab-audio-muting to Enabled, relaunch Chrome, and start Ad Muting again.")
            }
            guard try chrome.advertisedActions(binding.button).contains(kAXPressAction) else {
                throw AccessibilityFailure("Chrome's tab audio button does not advertise AXPress.")
            }
        }
        let first = try audioState(of: binding.tab)
        let second = try audioState(of: binding.tab)
        guard first == second else {
            throw AudioStatePending()
        }
        return first
    }

    @discardableResult
    func pressOnce(_ binding: ChromeTabAudioBinding) -> AXError {
        chrome.performOnce(kAXPressAction, on: binding.button)
    }

    func waitForState(
        _ expected: ChromeTabAudioState,
        binding: ChromeTabAudioBinding,
        pressResult: AXError,
        isCancelled: () -> Bool
    ) throws -> ChromeTabAudioState {
        let deadline = Date().addingTimeInterval(readbackTimeout)
        repeat {
            if isCancelled() { throw MonitoringCancelled() }
            do {
                let current = try checkedState(of: binding, validateAction: false, validateMapping: true)
                if current == expected { return current }
            } catch is AudioStatePending {
                // Chrome can update title and description in separate AX turns.
                // Permit read-only convergence, but never retry the press.
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw AccessibilityFailure("AXPress returned \(pressResult.rawValue), but Chrome tab audio readback was not verified. No press was retried.", axError: pressResult)
    }

    private func bind(_ areas: [ChromeWatchArea], window: AXUIElement) throws -> [ChromeTabAudioBinding] {
        guard areas.count == 1 || areas.count == 2 else {
            throw AccessibilityFailure("Expected one normal Hulu page or two split Hulu pages in a Chrome window; found \(areas.count).")
        }
        let candidates = try tabCandidates(in: window)
        if areas.count == 1 {
            guard areas[0].visibleAreaCountInWindow == 1 else {
                throw AccessibilityFailure("A single Hulu page can be bound only when it is the window's single visible top-level web area.")
            }
            let selected = candidates.filter(\.selected)
            guard selected.count == 1, let tab = selected.first else {
                throw AccessibilityFailure("One visible Hulu page requires exactly one selected native Chrome tab.")
            }
            return [try binding(area: areas[0], tab: tab, side: nil, peerArea: nil, peerTab: nil)]
        }

        guard areas.allSatisfy({ $0.visibleAreaCountInWindow == 2 }) else {
            throw AccessibilityFailure("Two Hulu split pages must be the window's only two visible top-level web areas.")
        }

        let selected = candidates.filter(\.selected)
        let sided = Dictionary(grouping: selected.compactMap { candidate in
            candidate.side.map { ($0, candidate) }
        }, by: \.0)
        guard selected.count == 2,
              sided[.left]?.count == 1, let leftTab = sided[.left]?.first?.1,
              sided[.right]?.count == 1, let rightTab = sided[.right]?.first?.1 else {
            throw AccessibilityFailure("Two visible Hulu pages require exactly one Left view and one Right view native Chrome tab.")
        }
        let framed = try areas.map { area in (area, try frame(of: area.webArea)) }
        guard let leftArea = framed.min(by: { $0.1.midX < $1.1.midX }),
              let rightArea = framed.max(by: { $0.1.midX < $1.1.midX }),
              !CFEqual(leftArea.0.webArea, rightArea.0.webArea),
              leftArea.1.maxX <= rightArea.1.minX,
              leftArea.1.maxY > rightArea.1.minY,
              rightArea.1.maxY > leftArea.1.minY else {
            throw AccessibilityFailure("Split Hulu web areas do not expose unique non-overlapping horizontal geometry.")
        }
        return [
            try binding(area: leftArea.0, tab: leftTab, side: .left, peerArea: rightArea.0.webArea, peerTab: rightTab.element),
            try binding(area: rightArea.0, tab: rightTab, side: .right, peerArea: leftArea.0.webArea, peerTab: leftTab.element),
        ]
    }

    private func binding(
        area: ChromeWatchArea,
        tab: TabCandidate,
        side: SplitSide?,
        peerArea: AXUIElement?,
        peerTab: AXUIElement?
    ) throws -> ChromeTabAudioBinding {
        guard let button = tab.button else {
            throw AccessibilityFailure("The selected Chrome tab does not expose a native Mute tab or Unmute tab button. Set chrome://flags/#enable-tab-audio-muting to Enabled, relaunch Chrome, and start Ad Muting again.")
        }
        guard titleMatches(tab.title, webAreaTitle: area.title) else {
            throw AccessibilityFailure("Chrome native tab title does not match its candidate Hulu web area title.")
        }
        let state: ChromeTabAudioState
        do {
            state = try audioState(title: tab.title, description: tab.nodeDescription)
        } catch is AudioStatePending {
            throw AccessibilityFailure("Chrome native tab has missing or conflicting Audio playing/Audio muted state.")
        }
        return ChromeTabAudioBinding(
            window: area.window,
            webArea: area.webArea,
            url: area.url,
            tab: tab.element,
            button: button,
            state: state,
            webAreaTitle: area.title,
            viewCount: area.visibleAreaCountInWindow,
            splitSide: side == .left ? "left" : (side == .right ? "right" : nil),
            peerWebArea: peerArea,
            peerTab: peerTab
        )
    }

    private func tabCandidates(in window: AXUIElement) throws -> [TabCandidate] {
        let nodes = try chrome.inspect(
            window,
            maximumNodes: 1_500,
            maximumDepth: 30,
            timeout: 5,
            stopDescending: { $0.role == "AXWebArea" }
        )
        var result: [TabCandidate] = []
        for node in nodes where node.role == kAXRadioButtonRole && !node.hidden {
            let children = try chrome.attribute(node.element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let audioButtons = try children.filter { child in
                try chrome.text(child, kAXRoleAttribute) == kAXButtonRole &&
                    ["Mute tab", "Unmute tab"].contains(chrome.text(child, kAXTitleAttribute))
            }
            guard audioButtons.count <= 1 else {
                throw AccessibilityFailure("A native Chrome tab exposes ambiguous audio buttons.")
            }
            let selected = try selectedState(of: node.element)
            let side = selected ? try splitSide(title: node.title, description: node.nodeDescription) : nil
            result.append(TabCandidate(
                element: node.element,
                button: audioButtons.first,
                title: node.title,
                nodeDescription: node.nodeDescription,
                side: side,
                selected: selected
            ))
        }
        return result
    }

    private func audioState(of tab: AXUIElement) throws -> ChromeTabAudioState {
        try audioState(
            title: chrome.text(tab, kAXTitleAttribute),
            description: chrome.text(tab, kAXDescriptionAttribute)
        )
    }

    private func audioState(title: String, description: String) throws -> ChromeTabAudioState {
        let tokens = [title, description].flatMap(Self.decorations)
        let states = Set(tokens.compactMap { token -> ChromeTabAudioState? in
            if token == "Audio playing" { return .playing }
            if token == "Audio muted" { return .muted }
            return nil
        })
        guard states.count == 1, let state = states.first else { throw AudioStatePending() }
        return state
    }

    private func splitSide(title: String, description: String) throws -> SplitSide? {
        let tokens = [title, description].flatMap(Self.decorations)
        let sides = Set(tokens.compactMap { token -> SplitSide? in
            if token == "Left view" { return .left }
            if token == "Right view" { return .right }
            return nil
        })
        guard sides.count <= 1 else {
            throw AccessibilityFailure("Chrome native tab has conflicting split-side state.")
        }
        return sides.first
    }

    private func titleMatches(_ title: String, webAreaTitle: String) -> Bool {
        !webAreaTitle.isEmpty && (title == webAreaTitle || title.hasPrefix(webAreaTitle + " - "))
    }

    private func validateCurrentMapping(_ binding: ChromeTabAudioBinding) throws {
        let selected = try tabCandidates(in: binding.window).filter(\.selected)
        guard selected.count == binding.viewCount,
              let current = selected.first(where: { CFEqual($0.element, binding.tab) }),
              current.button.map({ CFEqual($0, binding.button) }) == true else {
            throw AccessibilityFailure("Chrome's selected native tab mapping changed immediately before action.")
        }
        let currentSide = current.side == .left ? "left" : (current.side == .right ? "right" : nil)
        guard currentSide == binding.splitSide else {
            throw AccessibilityFailure("Chrome's split-side mapping changed immediately before action.")
        }
        if let peer = binding.peerWebArea, let side = binding.splitSide {
            guard try chrome.attribute(peer, "AXHidden") as? Bool != true else {
                throw AccessibilityFailure("Chrome's peer split web area disappeared immediately before action.")
            }
            let ownFrame = try frame(of: binding.webArea)
            let peerFrame = try frame(of: peer)
            let ordered = side == "left" ? ownFrame.maxX <= peerFrame.minX : peerFrame.maxX <= ownFrame.minX
            guard ordered, ownFrame.maxY > peerFrame.minY, peerFrame.maxY > ownFrame.minY else {
                throw AccessibilityFailure("Chrome's split web-area geometry changed immediately before action.")
            }
        }
    }

    private func validateDirectSelection(_ binding: ChromeTabAudioBinding) throws {
        guard try selectedState(of: binding.tab) else {
            throw AccessibilityFailure("Chrome's bound native tab is no longer selected.")
        }
        let title = try chrome.text(binding.tab, kAXTitleAttribute)
        let description = try chrome.text(binding.tab, kAXDescriptionAttribute)
        let currentSide = try splitSide(title: title, description: description)
        let expectedSide: SplitSide? = binding.splitSide == "left" ? .left : (binding.splitSide == "right" ? .right : nil)
        guard currentSide == expectedSide else {
            throw AccessibilityFailure("Chrome's bound native tab changed split side.")
        }
        if let peerTab = binding.peerTab, let expectedSide {
            guard try selectedState(of: peerTab) else {
                throw AccessibilityFailure("Chrome's peer split tab is no longer selected.")
            }
            let peerSide = try splitSide(
                title: chrome.text(peerTab, kAXTitleAttribute),
                description: chrome.text(peerTab, kAXDescriptionAttribute)
            )
            guard peerSide == (expectedSide == .left ? .right : .left) else {
                throw AccessibilityFailure("Chrome's peer native tab changed split side.")
            }
        }
    }

    private static func decorations(_ value: String) -> [String] {
        value.components(separatedBy: " - ")
    }

    private func selectedState(of tab: AXUIElement) throws -> Bool {
        if let selected = try chrome.attribute(tab, "AXSelected") as? Bool { return selected }
        if let value = try chrome.attribute(tab, kAXValueAttribute) as? Bool { return value }
        if let value = try chrome.attribute(tab, kAXValueAttribute) as? NSNumber { return value.boolValue }
        return false
    }

    private func currentURL(of webArea: AXUIElement) throws -> String? {
        let raw = try chrome.attribute(webArea, kAXURLAttribute)
        return (raw as? URL)?.absoluteString ?? raw as? String
    }

    private func frame(of element: AXUIElement) throws -> CGRect {
        guard let positionValue = try chrome.attribute(element, kAXPositionAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = try chrome.attribute(element, kAXSizeAttribute),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw AccessibilityFailure("Split Hulu web area geometry is unavailable.")
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            throw AccessibilityFailure("Split Hulu web area geometry is invalid.")
        }
        return CGRect(origin: point, size: size)
    }
}
