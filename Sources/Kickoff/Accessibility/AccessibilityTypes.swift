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
