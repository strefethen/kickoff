import ApplicationServices
import CAXNavigation
import Foundation

enum ChromeAddressEntryPlan: Equatable {
    case submitExactValue
    case removeSelectedSuffix
}

enum ChromeAddressEntryPolicy {
    static func plan(
        expected: String,
        actual: String,
        selectedText: String?,
        selectedRange: CFRange?
    ) -> ChromeAddressEntryPlan? {
        if actual == expected { return .submitExactValue }
        guard let selectedText, !selectedText.isEmpty,
              let selectedRange,
              selectedRange.location == expected.utf16.count,
              selectedRange.length == selectedText.utf16.count,
              actual == expected + selectedText else {
            return nil
        }
        return .removeSelectedSuffix
    }
}

protocol ChromeAddressFieldAccessing: AnyObject {
    func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef?
    func text(_ element: AXUIElement, _ name: String) throws -> String
    func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws
}

extension ChromeAccessibilityClient: ChromeAddressFieldAccessing {}

/// Owns exact omnibox entry, one-shot selected-suffix removal, and Return delivery.
struct ChromeAddressEntry {
    typealias KeyPost = () -> AXError

    let chrome: ChromeAddressFieldAccessing
    let addressField: AXUIElement
    let expected: String
    let validateRecipient: () throws -> Void
    let postBackspace: KeyPost
    let postReturn: KeyPost
    let logKeyResult: (_ event: String, _ result: AXError) -> Void
    let readbackTimeout: TimeInterval
    let valueAttempts: Int
    let pause: (TimeInterval) -> Void

    init(
        chrome: ChromeAddressFieldAccessing,
        addressField: AXUIElement,
        expected: String,
        validateRecipient: @escaping () throws -> Void,
        postBackspace: @escaping KeyPost = KickoffAXBackspaceToFrontmost,
        postReturn: @escaping KeyPost = HuluAXReturnToFrontmost,
        logKeyResult: @escaping (_ event: String, _ result: AXError) -> Void,
        readbackTimeout: TimeInterval = 1,
        valueAttempts: Int = 5,
        pause: @escaping (TimeInterval) -> Void = Thread.sleep
    ) {
        self.chrome = chrome
        self.addressField = addressField
        self.expected = expected
        self.validateRecipient = validateRecipient
        self.postBackspace = postBackspace
        self.postReturn = postReturn
        self.logKeyResult = logKeyResult
        self.readbackTimeout = readbackTimeout
        self.valueAttempts = valueAttempts
        self.pause = pause
    }

    func submit() throws {
        switch try enterExpectedValue() {
        case .submitExactValue:
            break
        case .removeSelectedSuffix:
            try removeSelectedSuffix()
        }

        try validateRecipient()
        guard try chrome.text(addressField, kAXValueAttribute) == expected else {
            throw AccessibilityFailure("The configured website address changed immediately before submission. No Return was sent.")
        }
        let result = postReturn()
        logKeyResult("submit-website", result)
        guard result == .success else {
            throw AccessibilityFailure("Submitting the configured website address failed with AX error \(result.rawValue).", axError: result)
        }
    }

    private func enterExpectedValue() throws -> ChromeAddressEntryPlan {
        var shown = ""
        for attempt in 1...max(valueAttempts, 1) {
            if attempt > 1 { pause(0.25) }
            try chrome.set(addressField, attribute: kAXValueAttribute, value: expected as CFString)
            try validateRecipient()
            if let plan = try plan() { return plan }
            shown = try chrome.text(addressField, kAXValueAttribute)
            logKeyResult("address-value-rewritten", .success)
        }
        throw AccessibilityFailure("Chrome kept changing the configured website address (it showed \"\(shown)\") after \(max(valueAttempts, 1)) attempts. No Backspace or Return was sent.")
    }

    private func removeSelectedSuffix() throws {
        try validateRecipient()
        guard try plan() == .removeSelectedSuffix else {
            throw AccessibilityFailure("Chrome's selected autocomplete suffix changed. No Backspace or Return was sent.")
        }

        let result = postBackspace()
        logKeyResult("remove-autocomplete-suffix", result)
        guard result == .success else {
            throw AccessibilityFailure("Removing Chrome's selected autocomplete suffix failed with AX error \(result.rawValue). No Return was sent.", axError: result)
        }

        let deadline = Date().addingTimeInterval(readbackTimeout)
        repeat {
            try validateRecipient()
            if try chrome.text(addressField, kAXValueAttribute) == expected { return }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        throw AccessibilityFailure("Chrome's selected autocomplete suffix did not clear to the configured website address. No Return was sent.")
    }

    private func plan() throws -> ChromeAddressEntryPlan? {
        let actual = try chrome.text(addressField, kAXValueAttribute)
        if actual == expected { return .submitExactValue }
        return ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: actual,
            selectedText: try selectedText(),
            selectedRange: try selectedRange()
        )
    }

    private func selectedText() throws -> String? {
        try chrome.attribute(addressField, kAXSelectedTextAttribute) as? String
    }

    private func selectedRange() throws -> CFRange? {
        guard let raw = try chrome.attribute(addressField, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}
