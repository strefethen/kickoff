import AppKit
import XCTest
@testable import Kickoff

final class SetupMenuControllerTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    func testNativeStructureUsesDirectDisplaysAndExclusiveIconPalette() throws {
        let fixture = SetupMenuFixture()
        let controller = fixture.controller()
        let menu = controller.menu
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["Display", "Layout", "Website"])
        XCTAssertEqual(menu.items.filter { $0.representedObject is String }.count, 2)
        XCTAssertEqual(menu.items.first { $0.representedObject as? String == "external" }?.state, .on)
        XCTAssertEqual(controller.layoutMenu.presentationStyle, .palette)
        XCTAssertEqual(controller.layoutMenu.selectionMode, .selectOne)
        XCTAssertEqual(controller.layoutMenu.items.count, 3)
        XCTAssertEqual(controller.layoutMenu.selectedItems.map(\.tag), [1])
        let choices = controller.layoutMenu.items
        XCTAssertTrue(choices.allSatisfy { $0.target === controller && $0.action == choices[0].action && $0.image != nil && $0.toolTip == $0.title })
        XCTAssertTrue(menu.items.allSatisfy { $0.view == nil })
        XCTAssertEqual(menu.items.filter { $0.title == "Set Up Chrome" }.count, 1)
        XCTAssertNil(menu.item(withTitle: "Monitor"))
        XCTAssertEqual(menu.item(withTitle: "Edit Website…")?.keyEquivalent, ",")
    }

    func testDisplaySelectionPersistsAndMissingPreferenceFallsBackWithoutOverwrite() throws {
        let fixture = SetupMenuFixture()
        let controller = fixture.controller()
        send(try XCTUnwrap(controller.menu.items.first { $0.representedObject as? String == "main" }))
        XCTAssertEqual(fixture.selection.snapshot().preferred?.identifier, "main")
        fixture.monitors.removeAll { $0.identifier == "main" }
        controller.refresh()
        XCTAssertEqual(fixture.selection.snapshot().target?.identifier, "external")
        XCTAssertEqual(fixture.selection.snapshot().unavailablePreference?.identifier, "main")
        XCTAssertTrue(controller.menu.items.contains { $0.title.hasPrefix("Saved display unavailable:") })
        XCTAssertEqual(controller.menu.items.first { $0.representedObject as? String == "external" }?.state, .on)
        fixture.monitors.append(SetupMenuFixture.display("main", name: "Built-in Retina Display", primary: true))
        controller.refresh()
        XCTAssertEqual(fixture.selection.snapshot().target?.identifier, "main")
    }

    func testDuplicateNamesAndStaleDisplayAction() throws {
        let fixture = SetupMenuFixture()
        fixture.monitors = [SetupMenuFixture.display("a", name: "DELL"), SetupMenuFixture.display("b", name: "DELL")]
        let controller = fixture.controller()
        let choices = controller.menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(choices.map(\.title), ["DELL (1)", "DELL (2)"])
        fixture.monitors.removeLast()
        send(choices[1])
        XCTAssertNil(fixture.selection.snapshot().preferred)
        XCTAssertEqual(fixture.selection.snapshot().target?.identifier, "a")
    }

    func testAllModesDispatchExactlyOnceAndSelectionIsSessionOnly() throws {
        for (index, mode) in [ChromeSetupMode.single, .split, .quad].enumerated() {
            let fixture = SetupMenuFixture()
            let controller = fixture.controller()
            send(controller.layoutMenu.items[index])
            XCTAssertEqual(controller.selectedLayout, mode)
            XCTAssertEqual(controller.layoutMenu.selectedItems.map(\.tag), [index])
            let setup = try XCTUnwrap(controller.menu.item(withTitle: "Set Up Chrome"))
            send(setup)
            send(setup)
            XCTAssertEqual(fixture.setups, [mode])
            XCTAssertEqual(fixture.controller().selectedLayout, .split)
        }
    }

    func testFreshRuntimeGuardsPermissionSetupNoDisplaysAndQuit() throws {
        let fixture = SetupMenuFixture()
        let controller = fixture.controller()
        let setup = try XCTUnwrap(controller.menu.item(withTitle: "Set Up Chrome"))
        fixture.runtime.accessibilityTrusted = false
        send(setup)
        XCTAssertTrue(fixture.setups.isEmpty)
        XCTAssertFalse(controller.menu.item(withTitle: "Set Up Chrome")!.isEnabled)
        XCTAssertNotNil(controller.menu.item(withTitle: "Open Accessibility Settings…"))
        fixture.runtime.accessibilityTrusted = true
        fixture.monitors = []
        send(setup)
        XCTAssertTrue(fixture.setups.isEmpty)
        fixture.monitors = [SetupMenuFixture.display("a", name: "Display")]
        fixture.runtime.isQuitting = true
        send(setup)
        XCTAssertTrue(fixture.setups.isEmpty)
        XCTAssertFalse(controller.menu.item(withTitle: "Set Up Chrome")!.isEnabled)
    }

    func testSetupDisablesDisplayLayoutEditAndRecoveryActions() throws {
        let fixture = SetupMenuFixture()
        fixture.runtime.accessibilityTrusted = false
        let controller = fixture.controller()
        let display = try XCTUnwrap(controller.menu.items.first { $0.representedObject as? String == "main" })
        let edit = try XCTUnwrap(controller.menu.item(withTitle: "Edit Website…"))
        let permission = try XCTUnwrap(controller.menu.item(withTitle: "Open Accessibility Settings…"))
        let finder = try XCTUnwrap(controller.menu.item(withTitle: "Show App in Finder"))
        fixture.runtime.isSettingUp = true
        send(display); send(controller.layoutMenu.items[2]); send(edit); send(permission); send(finder)
        XCTAssertNil(fixture.selection.snapshot().preferred)
        XCTAssertEqual(controller.selectedLayout, .split)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testInvalidWebsiteAndSavedURLRefreshWithoutFallback() throws {
        let fixture = SetupMenuFixture()
        fixture.defaults.set("file:///bad", forKey: "websiteURL")
        let controller = fixture.controller()
        send(try XCTUnwrap(controller.menu.item(withTitle: "Set Up Chrome")))
        XCTAssertTrue(fixture.setups.isEmpty)
        XCTAssertNotNil(controller.menu.item(withTitle: "file:///bad"))
        XCTAssertFalse(controller.menu.item(withTitle: "Set Up Chrome")!.isEnabled)
        let draft = fixture.preferences.makeDraft()
        draft.update("example.com/game")
        _ = try draft.save()
        controller.refresh()
        XCTAssertNotNil(controller.menu.item(withTitle: "https://example.com/game"))
        XCTAssertTrue(controller.menu.item(withTitle: "Set Up Chrome")!.isEnabled)
    }

    func testLongWebsiteAndStatusUseBoundedTitlesAndFullHelp() throws {
        let fixture = SetupMenuFixture()
        let website = "https://example.com/" + String(repeating: "long-path/", count: 20)
        fixture.defaults.set(website, forKey: "websiteURL")
        fixture.runtime.status = String(repeating: "Long monitoring status ", count: 10)
        let controller = fixture.controller()
        let websiteItem = try XCTUnwrap(controller.menu.items.first { $0.toolTip == website })
        XCTAssertEqual(websiteItem.title.count, 48)
        XCTAssertEqual(websiteItem.value(forKey: "accessibilityLabel") as? String, website)
        XCTAssertEqual(controller.menu.items[0].title.count, 48)
        XCTAssertEqual(controller.menu.items[0].toolTip, fixture.runtime.status)
    }

    func testTrackingRefreshPreservesNativeItemIdentityAndUpdatesState() throws {
        let fixture = SetupMenuFixture()
        let controller = fixture.controller()
        controller.menuWillOpen(controller.menu)
        let original = controller.menu.items
        let originalLayout = controller.layoutMenu.items
        let muting = try XCTUnwrap(controller.menu.item(withTitle: "Ad Muting"))
        fixture.runtime.status = "Ad muting running"
        fixture.runtime.isMonitoring = true
        fixture.monitors.append(SetupMenuFixture.display("new", name: "New Display"))
        controller.refresh()
        XCTAssertEqual(controller.menu.items.count, original.count)
        XCTAssertTrue(zip(original, controller.menu.items).allSatisfy { $0 === $1 })
        XCTAssertTrue(zip(originalLayout, controller.layoutMenu.items).allSatisfy { $0 === $1 })
        XCTAssertEqual(controller.menu.items[0].title, "Ad muting running")
        XCTAssertEqual(muting.state, .on)
        send(controller.layoutMenu.items[0])
        XCTAssertEqual(controller.layoutMenu.selectedItems.map(\.tag), [0])
        XCTAssertTrue(zip(original, controller.menu.items).allSatisfy { $0 === $1 })
        controller.menuDidClose(controller.menu)
        XCTAssertEqual(controller.menu.items.filter { $0.representedObject is String }.count, 3)
    }

    func testTrackingHotplugDisablesStaleRowAndSetupAfterAllDisplaysLeave() throws {
        let fixture = SetupMenuFixture()
        let controller = fixture.controller()
        controller.menuWillOpen(controller.menu)
        let display = try XCTUnwrap(controller.menu.items.first { $0.representedObject as? String == "external" })
        fixture.monitors = []
        controller.refresh()
        XCTAssertFalse(display.isEnabled)
        XCTAssertFalse(controller.menu.item(withTitle: "Set Up Chrome")!.isEnabled)
        controller.menuDidClose(controller.menu)
    }

    func testAdMutingAndSecondaryActionRoutes() throws {
        let fixture = SetupMenuFixture()
        fixture.runtime.accessibilityTrusted = false
        fixture.runtime.isMonitoring = true
        let controller = fixture.controller()
        send(try XCTUnwrap(controller.menu.item(withTitle: "Ad Muting")))
        XCTAssertEqual(fixture.events, ["toggle"])
        for title in ["Edit Website…", "Open Accessibility Settings…", "Show App in Finder", "Quit Kickoff"] {
            send(try XCTUnwrap(controller.menu.item(withTitle: title)))
        }
        XCTAssertEqual(fixture.events, ["toggle", "edit", "permission", "finder", "quit"])
    }

    /// Optional real native status menu; every automation action remains fake.
    func testNativeMenuFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let scenario = env["KICKOFF_MENU_FIXTURE"] else { return }
        let fixture = SetupMenuFixture()
        if scenario == "empty" { fixture.monitors = [] }
        if scenario == "unavailable" { _ = fixture.selection.select(identifier: "external"); fixture.monitors.removeLast() }
        if scenario == "permission" { fixture.runtime.accessibilityTrusted = false }
        if scenario == "long" {
            fixture.monitors = (0..<5).map { SetupMenuFixture.display("display-\($0)", name: "Professional UltraWide Display \($0)", primary: $0 == 0) }
            fixture.defaults.set("https://example.com/live/sports/long-path?channel=football&subscription=example", forKey: "websiteURL")
        }
        let controller = fixture.controller()
        let settings = SettingsWindowController(preferences: fixture.preferences)
        settings.onSave = { controller.refresh() }
        fixture.edit = { settings.show() }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        AppMenuController().install(quitTarget: controller, quitAction: Selector(("quit")))
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "american.football", accessibilityDescription: "Kickoff native menu fixture")
        status.button?.image?.isTemplate = true
        status.button?.setAccessibilityLabel("Kickoff native menu fixture")
        status.menu = controller.menu
        defer { NSStatusBar.system.removeStatusItem(status) }
        let deadline = Date().addingTimeInterval(Double(env["KICKOFF_MENU_HOLD_SECONDS"] ?? "30") ?? 30)
        let timer = Timer(timeInterval: 2.5, repeats: true) { _ in controller.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print("NATIVE_MENU_FIXTURE_RESULT events=\(fixture.events) setups=\(fixture.setups) target=\(fixture.selection.snapshot().target?.identifier ?? "none") mode=\(controller.selectedLayout) website=\(try fixture.preferences.currentURL().absoluteString)")
        controller.menu.cancelTracking()
        settings.window?.close()
    }

    private func send(_ item: NSMenuItem) {
        guard let action = item.action else { XCTFail("Missing action"); return }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
}

private final class SetupMenuFixture {
    let suite = "SetupMenuFixture.\(UUID().uuidString)"
    let defaults: UserDefaults
    var monitors = [display("main", name: "Built-in Retina Display", primary: true), display("external", name: "Studio Display", x: 1920)]
    var runtime = SetupMenuController.RuntimeState(accessibilityTrusted: true)
    var setups: [ChromeSetupMode] = []
    var events: [String] = []
    var edit: (() -> Void)?
    lazy var selection = MonitorSelection(defaults: defaults, discover: { [unowned self] in self.monitors })
    lazy var preferences = WebsitePreferences(defaults: defaults)

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }

    func controller() -> SetupMenuController {
        SetupMenuController(selection: selection, preferences: preferences, readRuntime: { [unowned self] in self.runtime }, actions: .init(
            setUp: { [unowned self] mode in self.setups.append(mode); self.runtime.isSettingUp = true },
            toggleAdMuting: { [unowned self] in self.events.append("toggle"); self.runtime.isMonitoring.toggle() },
            editWebsite: { [unowned self] in self.events.append("edit"); self.edit?() },
            openAccessibilitySettings: { [unowned self] in self.events.append("permission") },
            showAppInFinder: { [unowned self] in self.events.append("finder") },
            quit: { [unowned self] in self.events.append("quit") }
        ))
    }

    static func display(_ id: String, name: String, primary: Bool = false, x: CGFloat = 0) -> Monitor {
        let bounds = CGRect(x: x, y: 0, width: 1920, height: 1080)
        return Monitor(identifier: id, displayID: primary ? 1 : 2, name: name, isPrimary: primary, bounds: bounds, visibleBounds: bounds)
    }
}
