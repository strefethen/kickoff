import ApplicationServices
import Foundation

/// Owns supported routes and complete, player-scoped provider evidence.
/// Browser tab binding and audio mutation stay in ChromeTabAudioClient.
enum PlayerAdDetection: Equatable {
    case hulu
    case peacock

    static func provider(for value: String) -> PlayerAdDetection? {
        guard let url = URL(string: value), url.scheme == "https" else { return nil }
        switch url.host {
        case "hulu.com", "www.hulu.com":
            return url.path.hasPrefix("/watch/") ? .hulu : nil
        case "peacocktv.com", "www.peacocktv.com":
            let prefix = "/watch/playback/"
            return url.path.hasPrefix(prefix) && url.path.count > prefix.count ? .peacock : nil
        default:
            return nil
        }
    }

    var rootIdentifier: String {
        switch self {
        case .hulu: return "__player__"
        case .peacock: return "mainContainer"
        }
    }

    func isMarker(_ node: AccessibilityNode) -> Bool {
        guard !node.hidden else { return false }
        switch self {
        case .hulu:
            return node.role == kAXStaticTextRole && AdMarker.matches(node.value)
        case .peacock:
            return node.role == kAXGroupRole && Self.activeOverlay(classes: node.domClassList)
        }
    }

    static func activeOverlay(classes: [String]) -> Bool {
        func hasToken(_ base: String) -> Bool {
            classes.contains { $0 == base || ($0.hasPrefix(base + "-") && $0.count > base.count + 1) }
        }
        return hasToken("pffOverlay") && hasToken("adBreakActive")
    }

    struct Marker {
        let element: AXUIElement
        let ancestors: [AXUIElement]
    }

    struct Evidence {
        let root: AXUIElement
        let requiredAnchor: AXUIElement?
        let requiredAnchorIdentifier: String?
        let markers: [Marker]
    }

    func read(in area: AXUIElement, chrome: ChromeAccessibilityAccessing) throws -> Evidence {
        let areaNodes = try chrome.inspect(
            area, maximumNodes: 1_500, maximumDepth: 45, timeout: 5,
            stopDescending: { ($0.depth > 0 && $0.role == "AXWebArea") || $0.domIdentifier == rootIdentifier }
        )
        let roots = Self.withoutNestedWebAreas(areaNodes).filter {
            $0.role != "AXWebArea" && $0.domIdentifier == rootIdentifier && !$0.hidden
        }
        guard roots.count == 1, let root = roots.first else {
            throw AccessibilityFailure("Supported playback page does not expose one visible \(rootIdentifier) container.")
        }
        let nodes = Self.withoutNestedWebAreas(try chrome.inspect(
            root.element, maximumNodes: 1_200, maximumDepth: 35, timeout: 4,
            stopDescending: { $0.depth > 0 && $0.role == "AXWebArea" }
        ))
        guard let observedRoot = nodes.first, CFEqual(observedRoot.element, root.element),
              observedRoot.domIdentifier == rootIdentifier, !observedRoot.hidden else {
            throw AccessibilityFailure("Player container changed or became hidden during the complete evidence scan.")
        }
        let anchor = try requiredAnchor(in: nodes)
        var lineage: [AccessibilityNode] = []
        var markers: [Marker] = []
        for node in nodes {
            while let last = lineage.last, last.depth >= node.depth { lineage.removeLast() }
            if isMarker(node) {
                markers.append(Marker(element: node.element, ancestors: lineage.map(\.element)))
            }
            lineage.append(node)
        }
        return Evidence(root: root.element, requiredAnchor: anchor?.element,
                        requiredAnchorIdentifier: anchor?.domIdentifier, markers: markers)
    }

    private func requiredAnchor(in nodes: [AccessibilityNode]) throws -> AccessibilityNode? {
        guard self == .peacock else { return nil }
        let anchors = Self.withoutNestedWebAreas(nodes).filter {
            $0.depth > 0 && !$0.hidden && ["core-video-shaka", "core-video-tape"].contains($0.domIdentifier)
        }
        guard anchors.count == 1, let anchor = anchors.first else {
            throw AccessibilityFailure("Peacock player does not expose one visible core-video-shaka or core-video-tape descendant; evidence is incomplete.")
        }
        return anchor
    }

    /// Only direct reads after action preparation. The final provider predicate is
    /// re-read here, and the caller performs no traversal before the audio press.
    func markerIsStillPresent(_ evidence: Evidence, chrome: ChromeAccessibilityAccessing) throws -> Bool {
        guard try chrome.attribute(evidence.root, "AXHidden") as? Bool != true else { return false }
        if let anchor = evidence.requiredAnchor {
            guard try chrome.attribute(anchor, "AXHidden") as? Bool != true,
                  try chrome.text(anchor, "AXDOMIdentifier") == evidence.requiredAnchorIdentifier else { return false }
        }
        for marker in evidence.markers {
            var visible = true
            for ancestor in marker.ancestors {
                if try chrome.attribute(ancestor, "AXHidden") as? Bool == true { visible = false; break }
            }
            guard visible, try chrome.attribute(marker.element, "AXHidden") as? Bool != true else { continue }
            switch self {
            case .hulu:
                if try chrome.text(marker.element, kAXRoleAttribute) == kAXStaticTextRole &&
                    AdMarker.matches(chrome.text(marker.element, kAXValueAttribute)) { return true }
            case .peacock:
                if try chrome.text(marker.element, kAXRoleAttribute) == kAXGroupRole &&
                    Self.activeOverlay(classes: chrome.domClassList(marker.element)) { return true }
            }
        }
        return false
    }

    /// inspect excludes descendants in production; this also excludes the nested
    /// web area itself and protects fixture/alternate readers that return a full tree.
    static func withoutNestedWebAreas(_ nodes: [AccessibilityNode]) -> [AccessibilityNode] {
        var nestedDepth: Int?
        return nodes.filter { node in
            if let depth = nestedDepth {
                if node.depth > depth { return false }
                nestedDepth = nil
            }
            if node.depth > 0 && node.role == "AXWebArea" {
                nestedDepth = node.depth
                return false
            }
            return true
        }
    }
}
