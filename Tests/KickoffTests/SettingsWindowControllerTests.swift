import AppKit
import Foundation
import XCTest
@testable import Kickoff

final class SettingsWindowControllerTests: XCTestCase {
    func testProgrammaticControllerConstructsReusableAccessibleWindowWithoutShowingIt() {
        _ = NSApplication.shared
        let suite = "SettingsWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = SettingsWindowController(preferences: WebsitePreferences(defaults: defaults))
        let window = controller.window

        XCTAssertTrue(controller.isWindowLoaded)
        XCTAssertEqual(window?.title, "Kickoff Settings")
        XCTAssertEqual(window?.isVisible, false)

        let descendants = window?.contentView.map(descendantViews) ?? []
        let websiteField = descendants.compactMap { $0 as? NSTextField }.first {
            $0.isEditable && ($0.value(forKey: "accessibilityLabel") as? String) == "Website URL"
        }
        let buttonTitles = descendants.compactMap { ($0 as? NSButton)?.title }
        XCTAssertNotNil(websiteField)
        XCTAssertTrue(buttonTitles.contains("Cancel"))
        XCTAssertTrue(buttonTitles.contains("Save"))
    }

    private func descendantViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }
}
