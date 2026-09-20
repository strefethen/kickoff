import ApplicationServices
import Foundation
import XCTest
@testable import Kickoff

final class ChromeAddressEntryTests: XCTestCase {
    private final class FakeChrome: ChromeAddressFieldAccessing {
        let field = AXUIElementCreateApplication(42)
        let valueAfterSet: String
        var actual: String
        var selectedText: String?
        var selectedRange: CFRange?
        var events: [String] = []

        init(valueAfterSet: String, selectedText: String? = nil, selectedRange: CFRange? = nil) {
            self.valueAfterSet = valueAfterSet
            actual = valueAfterSet
            self.selectedText = selectedText
            self.selectedRange = selectedRange
        }

        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            if name == kAXSelectedTextAttribute { return selectedText as CFString? }
            if name == kAXSelectedTextRangeAttribute, var selectedRange {
                return AXValueCreate(.cfRange, &selectedRange)
            }
            return nil
        }

        func text(_ element: AXUIElement, _ name: String) throws -> String {
            name == kAXValueAttribute ? actual : ""
        }

        func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws {
            XCTAssertEqual(attribute, kAXValueAttribute)
            events.append("set-value")
            actual = valueAfterSet
        }
    }

    func testPolicyAcceptsExactValueWithoutSelectionMetadata() {
        XCTAssertEqual(
            ChromeAddressEntryPolicy.plan(
                expected: "https://www.hulu.com/",
                actual: "https://www.hulu.com/",
                selectedText: nil,
                selectedRange: nil
            ),
            .submitExactValue
        )
    }

    func testPolicyAcceptsOnlyAnExactlySelectedAppendedSuffix() {
        let expected = "https://www.hulu.com/"
        let suffix = "live"
        XCTAssertEqual(
            ChromeAddressEntryPolicy.plan(
                expected: expected,
                actual: expected + suffix,
                selectedText: suffix,
                selectedRange: CFRange(location: expected.utf16.count, length: suffix.utf16.count)
            ),
            .removeSelectedSuffix
        )
    }

    func testPolicyRejectsPrefixChangesNonSuffixSelectionsAndMissingRanges() {
        let expected = "https://www.hulu.com/"
        let suffix = "live"
        let correct = CFRange(location: expected.utf16.count, length: suffix.utf16.count)

        XCTAssertNil(ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: "https://www.hulu.com.evil.test/" + suffix,
            selectedText: suffix,
            selectedRange: correct
        ))
        XCTAssertNil(ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: expected + suffix,
            selectedText: suffix,
            selectedRange: CFRange(location: expected.utf16.count - 1, length: suffix.utf16.count)
        ))
        XCTAssertNil(ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: expected + suffix,
            selectedText: nil,
            selectedRange: correct
        ))
        XCTAssertNil(ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: expected + suffix,
            selectedText: suffix,
            selectedRange: nil
        ))
        XCTAssertNil(ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: expected + suffix,
            selectedText: suffix,
            selectedRange: CFRange(location: expected.utf16.count, length: suffix.utf16.count - 1)
        ))
    }

    func testPolicyUsesUTF16Offsets() {
        let expected = "https://example.com/⚽️/"
        let suffix = "live"
        XCTAssertNotEqual(expected.count, expected.utf16.count)
        XCTAssertEqual(
            ChromeAddressEntryPolicy.plan(
                expected: expected,
                actual: expected + suffix,
                selectedText: suffix,
                selectedRange: CFRange(location: expected.utf16.count, length: suffix.utf16.count)
            ),
            .removeSelectedSuffix
        )
        XCTAssertNil(ChromeAddressEntryPolicy.plan(
            expected: expected,
            actual: expected + suffix,
            selectedText: suffix,
            selectedRange: CFRange(location: expected.count, length: suffix.count)
        ))
    }

    func testSubmitRemovesSuffixOnceThenRequiresExactReadbackBeforeReturn() throws {
        let expected = "https://www.hulu.com/"
        let suffix = "live"
        let chrome = FakeChrome(
            valueAfterSet: expected + suffix,
            selectedText: suffix,
            selectedRange: CFRange(location: expected.utf16.count, length: suffix.utf16.count)
        )
        let entry = makeEntry(chrome: chrome, expected: expected, backspace: {
            chrome.events.append("backspace")
            chrome.actual = expected
            chrome.selectedText = ""
            chrome.selectedRange = CFRange(location: expected.utf16.count, length: 0)
            return .success
        })

        try entry.submit()

        XCTAssertEqual(chrome.events, [
            "set-value", "validate", "validate", "backspace", "log-remove-autocomplete-suffix",
            "validate", "validate", "return", "log-submit-website",
        ])
    }

    func testFailedBackspaceReadbackNeverPostsReturnOrRetries() {
        let expected = "https://www.hulu.com/"
        let suffix = "live"
        let chrome = FakeChrome(
            valueAfterSet: expected + suffix,
            selectedText: suffix,
            selectedRange: CFRange(location: expected.utf16.count, length: suffix.utf16.count)
        )
        let entry = makeEntry(chrome: chrome, expected: expected, readbackTimeout: 0, backspace: {
            chrome.events.append("backspace")
            return .success
        })

        XCTAssertThrowsError(try entry.submit()) { error in
            XCTAssertTrue(String(describing: error).contains("did not clear"))
        }
        XCTAssertEqual(chrome.events.filter { $0 == "backspace" }.count, 1)
        XCTAssertFalse(chrome.events.contains("return"))
    }

    func testFailedBackspaceActionNeverPostsReturnOrRetries() {
        let expected = "https://www.hulu.com/"
        let suffix = "live"
        let chrome = FakeChrome(
            valueAfterSet: expected + suffix,
            selectedText: suffix,
            selectedRange: CFRange(location: expected.utf16.count, length: suffix.utf16.count)
        )
        let entry = makeEntry(chrome: chrome, expected: expected, backspace: {
            chrome.events.append("backspace")
            return .failure
        })

        XCTAssertThrowsError(try entry.submit()) { error in
            XCTAssertTrue(String(describing: error).contains("failed with AX error"))
        }
        XCTAssertEqual(chrome.events.filter { $0 == "backspace" }.count, 1)
        XCTAssertFalse(chrome.events.contains("return"))
    }

    func testUnexpectedAddressNeverPostsBackspaceOrReturn() {
        let expected = "https://www.hulu.com/"
        let chrome = FakeChrome(valueAfterSet: "https://www.hulu.com/live", selectedText: nil, selectedRange: nil)
        let entry = makeEntry(chrome: chrome, expected: expected, backspace: {
            XCTFail("Backspace must not be posted")
            return .success
        })

        XCTAssertThrowsError(try entry.submit())
        XCTAssertFalse(chrome.events.contains("return"))
    }

    func testFailedReturnActionIsReportedWithoutRetry() {
        let expected = "https://www.hulu.com/"
        let chrome = FakeChrome(valueAfterSet: expected)
        let entry = makeEntry(
            chrome: chrome,
            expected: expected,
            backspace: {
                XCTFail("Backspace must not be posted")
                return .success
            },
            returnResult: .failure
        )

        XCTAssertThrowsError(try entry.submit()) { error in
            XCTAssertTrue(String(describing: error).contains("Submitting the configured website address failed with AX error"))
        }
        XCTAssertEqual(chrome.events.filter { $0 == "return" }.count, 1)
        XCTAssertFalse(chrome.events.contains("backspace"))
    }

    private func makeEntry(
        chrome: FakeChrome,
        expected: String,
        readbackTimeout: TimeInterval = 1,
        backspace: @escaping () -> AXError,
        returnResult: AXError = .success
    ) -> ChromeAddressEntry {
        ChromeAddressEntry(
            chrome: chrome,
            addressField: chrome.field,
            expected: expected,
            validateRecipient: { chrome.events.append("validate") },
            postBackspace: backspace,
            postReturn: {
                chrome.events.append("return")
                return returnResult
            },
            logKeyResult: { event, _ in chrome.events.append("log-\(event)") },
            readbackTimeout: readbackTimeout
        )
    }
}
