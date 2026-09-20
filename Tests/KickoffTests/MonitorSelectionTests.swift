import CoreGraphics
import Foundation
import XCTest
@testable import Kickoff

final class MonitorSelectionTests: XCTestCase {
    private func monitor(
        _ identifier: String,
        id: CGDirectDisplayID,
        name: String = "Display",
        primary: Bool = false,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 1920,
        height: CGFloat = 1080,
        visibleInset: CGFloat = 20
    ) -> Monitor {
        let bounds = CGRect(x: x, y: y, width: width, height: height)
        return Monitor(
            identifier: identifier,
            displayID: id,
            name: name,
            isPrimary: primary,
            bounds: bounds,
            visibleBounds: bounds.insetBy(dx: visibleInset, dy: visibleInset)
        )
    }

    private func defaults() -> UserDefaults {
        let suite = "MonitorSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testPackagedAppUsesItsStandardDefaultsDomain() {
        XCTAssertEqual(
            AppPreferences.defaultDomain(bundleIdentifier: AppPreferences.suiteName),
            .standard
        )
    }

    func testUnbundledCLIUsesThePackagedAppSuite() {
        XCTAssertEqual(
            AppPreferences.defaultDomain(bundleIdentifier: nil),
            .suite(AppPreferences.suiteName)
        )
    }

    func testNoPreferenceUsesTheOnlyMonitor() throws {
        let only = monitor("only", id: 7, primary: true)
        let selection = MonitorSelection(defaults: defaults(), discover: { [only] })

        XCTAssertEqual(selection.snapshot().target, only)
    }

    func testNoPreferenceUsesNonprimaryWhenTwoMonitorsExist() throws {
        let primary = monitor("primary", id: 1, primary: true)
        let secondary = monitor("secondary", id: 2, x: 1920)
        let selection = MonitorSelection(defaults: defaults(), discover: { [primary, secondary] })

        XCTAssertEqual(selection.snapshot().target, secondary)
    }

    func testNoPreferenceUsesLeftmostNonprimaryWithStableTieBreaks() throws {
        let primary = monitor("primary", id: 1, primary: true)
        let right = monitor("right", id: 2, x: 1920)
        let lowerTie = monitor("z-lower", id: 3, x: -1920, y: 100)
        let upperTie = monitor("a-upper", id: 4, x: -1920, y: 0)
        let selection = MonitorSelection(
            defaults: defaults(),
            discover: { [right, lowerTie, primary, upperTie] }
        )

        XCTAssertEqual(selection.snapshot().target, upperTie)
    }

    func testFallbackUsesPrimaryFlagRatherThanDiscoveryOrFocusOrder() throws {
        let focusedFirst = monitor("focused-secondary", id: 8, x: 2560)
        let actualPrimary = monitor("quartz-primary", id: 9, primary: true)
        let selection = MonitorSelection(
            defaults: defaults(),
            discover: { [focusedFirst, actualPrimary] }
        )

        XCTAssertEqual(selection.snapshot().target, focusedFirst)
    }

    func testStoredChoiceWins() throws {
        let first = monitor("first", id: 1, x: -1920)
        let chosen = monitor("chosen", id: 2, primary: true)
        let selection = MonitorSelection(defaults: defaults(), discover: { [first, chosen] })

        XCTAssertTrue(selection.select(identifier: chosen.identifier))
        XCTAssertEqual(selection.snapshot().target, chosen)
    }

    func testUnavailablePreferenceFallsBackWithoutBeingOverwrittenAndReconnectWins() throws {
        let saved = monitor("saved", id: 10, name: "Projector", x: 1920)
        let fallback = monitor("fallback", id: 11, name: "Laptop", primary: true)
        var connected = [saved, fallback]
        let selection = MonitorSelection(defaults: defaults(), discover: { connected })
        XCTAssertTrue(selection.select(identifier: saved.identifier))

        connected = [fallback]
        let unavailable = selection.snapshot()
        XCTAssertEqual(unavailable.target, fallback)
        XCTAssertEqual(unavailable.preferred?.identifier, saved.identifier)
        XCTAssertEqual(unavailable.unavailablePreference?.name, "Projector")

        connected = [fallback, saved]
        XCTAssertEqual(selection.snapshot().target, saved)
    }

    func testUUIDChoiceSurvivesRuntimeDisplayIDChangeOnNewRun() throws {
        var connected = [monitor("stable-uuid", id: 12)]
        let selection = MonitorSelection(defaults: defaults(), discover: { connected })
        XCTAssertTrue(selection.select(identifier: "stable-uuid"))

        connected = [monitor("stable-uuid", id: 99)]
        let target = try selection.pinTarget()

        XCTAssertEqual(target.monitor.displayID, 99)
        XCTAssertEqual(try target.validate().displayID, 99)
    }

    func testDuplicateNamesRemainDistinctChoices() throws {
        let left = monitor("left", id: 1, name: "DELL", x: 0)
        let right = monitor("right", id: 2, name: "DELL", x: 1920)
        let selection = MonitorSelection(defaults: defaults(), discover: { [right, left] })
        let snapshot = selection.snapshot()

        XCTAssertEqual(snapshot.monitors.map(snapshot.title), ["DELL (1)", "DELL (2)"])
        XCTAssertTrue(selection.select(identifier: right.identifier))
        XCTAssertEqual(selection.snapshot().target?.identifier, right.identifier)
    }

    func testNoMonitorsHasNoTargetAndCannotPin() throws {
        let selection = MonitorSelection(defaults: defaults(), discover: { [] })

        XCTAssertNil(selection.snapshot().target)
        XCTAssertThrowsError(try selection.pinTarget())
    }

    func testStaleSelectionIsIgnored() throws {
        let stale = monitor("stale", id: 1)
        let current = monitor("current", id: 2)
        var connected = [stale]
        let selection = MonitorSelection(defaults: defaults(), discover: { connected })
        _ = selection.snapshot()
        connected = [current]

        XCTAssertFalse(selection.select(identifier: stale.identifier))
        XCTAssertNil(selection.snapshot().preferred)
        XCTAssertEqual(selection.snapshot().target, current)
    }

    func testPinnedTargetRejectsDisappearanceRuntimeIDAndBoundsChanges() throws {
        let original = monitor("target", id: 1, x: 100)
        var connected = [original]
        let target = MonitorTarget(monitor: original, discover: { connected })

        connected = []
        XCTAssertThrowsError(try target.validate())
        connected = [monitor("target", id: 2, x: 100)]
        XCTAssertThrowsError(try target.validate())
        connected = [monitor("target", id: 1, x: 101)]
        XCTAssertThrowsError(try target.validate())
    }

    func testPinnedTargetAllowsVisibleBoundsChange() throws {
        let original = monitor("target", id: 1, visibleInset: 20)
        var connected = [original]
        let target = MonitorTarget(monitor: original, discover: { connected })
        connected = [monitor("target", id: 1, visibleInset: 40)]

        XCTAssertEqual(try target.validate().visibleBounds, connected[0].visibleBounds)
    }
}
