import ApplicationServices
import Foundation

struct AccessibilityFailure: Error, CustomStringConvertible, Equatable {
    let description: String
    let axError: AXError?

    init(_ description: String, axError: AXError? = nil) {
        self.description = description
        self.axError = axError
    }
}

struct AccessibilityNode {
    let element: AXUIElement
    let role: String
    let title: String
    let nodeDescription: String
    let value: String
    let valueDescription: String
    let url: String?
    let domIdentifier: String
    /// True when this node or any traversed ancestor is hidden.
    let hidden: Bool
    let depth: Int
    let domClassList: [String]

    init(
        element: AXUIElement, role: String, title: String, nodeDescription: String,
        value: String, valueDescription: String, url: String?, domIdentifier: String,
        hidden: Bool, depth: Int, domClassList: [String] = []
    ) {
        self.element = element
        self.role = role
        self.title = title
        self.nodeDescription = nodeDescription
        self.value = value
        self.valueDescription = valueDescription
        self.url = url
        self.domIdentifier = domIdentifier
        self.hidden = hidden
        self.depth = depth
        self.domClassList = domClassList
    }
}

struct ChromeWindowSnapshot {
    let element: AXUIElement
    let index: Int
    let title: String
    let nodes: [AccessibilityNode]
}

struct PlayerContentNode: Equatable {
    let role: String
    let value: String

    init(role: String, value: String) {
        self.role = role
        self.value = value
    }
}
