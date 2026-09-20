import CoreGraphics
import Foundation
import XCTest
@testable import Kickoff

final class WebsitePreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "WebsitePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testBareAndFullURLsNormalizeSchemeHostAndEmptyPath() throws {
        XCTAssertEqual(try WebsiteURL("example.com").absoluteString, "https://example.com/")
        XCTAssertEqual(try WebsiteURL("example.com:8443/path").absoluteString, "https://example.com:8443/path")
        XCTAssertEqual(try WebsiteURL("http://example.com").absoluteString, "http://example.com/")
        XCTAssertEqual(try WebsiteURL("https://[::1]/path").absoluteString, "https://[::1]/path")
        XCTAssertEqual(
            try WebsiteURL("  HTTPS://EXAMPLE.COM/Case?x=AbC%2F#Frag  ").absoluteString,
            "https://example.com/Case?x=AbC%2F#Frag"
        )
    }

    func testPathsQueriesAndFragmentsRemainPartOfTheConfiguredAddress() throws {
        let website = try WebsiteURL("https://example.com/Watch/One?Team=A%2FB#Kickoff")

        XCTAssertEqual(website.absoluteString, "https://example.com/Watch/One?Team=A%2FB#Kickoff")
    }

    func testInvalidEmptyMalformedAndUnsupportedValuesAreRejected() {
        assertRejected("", as: .empty)
        assertRejected("   \n", as: .empty)
        assertRejected("ftp://example.com", as: .unsupportedScheme)
        assertRejected("mailto:someone@example.com", as: .unsupportedScheme)
        assertRejected("https://", as: .invalid)
        assertRejected("https://.example.com", as: .invalid)
        assertRejected("https://example..com", as: .invalid)
        assertRejected("https://example.com:", as: .invalid)
        assertRejected("https://example.com:0", as: .invalid)
        assertRejected("https://example.com:65536", as: .invalid)
        assertRejected("https://example.com/a path", as: .invalid)
        assertRejected("https://example.com/%ZZ", as: .invalid)
        assertRejected("https://[foo:bar]/", as: .invalid)
        assertRejected("//example.com/path", as: .invalid)
    }

    func testLoadedURLAcceptsSameHostWWWAndHTTPUpgrade() throws {
        let https = try WebsiteURL("https://example.com/start?one=1")
        XCTAssertTrue(https.acceptsLoadedURL("https://example.com/elsewhere?two=2"))
        XCTAssertTrue(https.acceptsLoadedURL("https://www.example.com/redirected"))
        XCTAssertTrue(https.acceptsLoadedURL("https://example.com:443/redirected"))
        XCTAssertFalse(https.acceptsLoadedURL("http://example.com/redirected"))

        let explicitHTTPS = try WebsiteURL("https://example.com:443/start")
        XCTAssertTrue(explicitHTTPS.acceptsLoadedURL("https://example.com/redirected"))

        let http = try WebsiteURL("http://www.example.com/start")
        XCTAssertTrue(http.acceptsLoadedURL("https://example.com/redirected"))
        XCTAssertTrue(http.acceptsLoadedURL("http://www.example.com/redirected"))

        let explicitHTTP = try WebsiteURL("http://example.com:80/start")
        XCTAssertTrue(explicitHTTP.acceptsLoadedURL("https://example.com:443/redirected"))
    }

    func testLoadedURLRejectsLookalikesSubdomainsAndUnexpectedPorts() throws {
        let website = try WebsiteURL("https://example.com/start")

        XCTAssertFalse(website.acceptsLoadedURL("https://example.com.evil.test/start"))
        XCTAssertFalse(website.acceptsLoadedURL("https://sub.example.com/start"))
        XCTAssertFalse(website.acceptsLoadedURL("https://wwwexample.com/start"))
        XCTAssertFalse(website.acceptsLoadedURL("https://example.com:8443/start"))
        XCTAssertNotNil(website.redirectFailure(for: ["https://evil.test/"]))
    }

    func testCustomPortMustSurviveRedirectAndHTTPMayUpgrade() throws {
        let website = try WebsiteURL("http://example.com:8080/start")

        XCTAssertTrue(website.acceptsLoadedURL("http://www.example.com:8080/next"))
        XCTAssertTrue(website.acceptsLoadedURL("https://example.com:8080/next"))
        XCTAssertFalse(website.acceptsLoadedURL("https://example.com/next"))
        XCTAssertFalse(website.acceptsLoadedURL("https://example.com:443/next"))
    }

    func testAbsentPreferenceUsesApprovedDefaultAndEmptyDraftDoesNotReplaceIt() throws {
        let preferences = WebsitePreferences(defaults: defaults())
        XCTAssertEqual(try preferences.currentURL(), .approvedDefault)

        let draft = preferences.makeDraft()
        draft.update("   ")
        XCTAssertThrowsError(try draft.save()) { error in
            XCTAssertEqual(error as? WebsiteValidationError, .empty)
        }
        XCTAssertEqual(try preferences.currentURL(), .approvedDefault)
    }

    func testDraftCancelDiscardsAndSavePersistsNormalizedValueForReopen() throws {
        let preferences = WebsitePreferences(defaults: defaults())
        let cancelled = preferences.makeDraft()
        cancelled.update("cancelled.example/path")
        cancelled.cancel()

        XCTAssertEqual(preferences.makeDraft().text, WebsiteURL.approvedDefault.absoluteString)

        let saved = preferences.makeDraft()
        saved.update(" Saved.Example/path?x=One#Top ")
        XCTAssertEqual(try saved.save().absoluteString, "https://saved.example/path?x=One#Top")
        XCTAssertEqual(preferences.makeDraft().text, "https://saved.example/path?x=One#Top")
        XCTAssertEqual(try preferences.currentURL().absoluteString, "https://saved.example/path?x=One#Top")
    }

    func testWebsiteSaveDoesNotChangeMonitorPreferenceInSharedDefaults() throws {
        let shared = defaults()
        let monitor = Monitor(
            identifier: "display-uuid",
            displayID: 42,
            name: "TV",
            isPrimary: false,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleBounds: CGRect(x: 0, y: 0, width: 1920, height: 1040)
        )
        let monitorSelection = MonitorSelection(defaults: shared, discover: { [monitor] })
        let websitePreferences = WebsitePreferences(defaults: shared)

        XCTAssertTrue(monitorSelection.select(identifier: monitor.identifier))
        let draft = websitePreferences.makeDraft()
        draft.update("https://example.com/game")
        try draft.save()

        XCTAssertEqual(monitorSelection.snapshot().preferred?.identifier, monitor.identifier)
        XCTAssertEqual(try websitePreferences.currentURL().absoluteString, "https://example.com/game")
    }

    private func assertRejected(
        _ value: String,
        as expected: WebsiteValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try WebsiteURL(value), file: file, line: line) { error in
            XCTAssertEqual(error as? WebsiteValidationError, expected, file: file, line: line)
        }
    }
}
