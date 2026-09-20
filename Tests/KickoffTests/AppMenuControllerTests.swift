import AppKit
import XCTest
@testable import Kickoff

final class AppMenuControllerTests: XCTestCase {
    private final class QuitTarget: NSObject {
        @objc func quit(_ sender: Any?) {}
    }

    func testInstallProvidesStandardResponderChainEditingAndSafeQuitTarget() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let target = QuitTarget()

        AppMenuController().install(quitTarget: target, quitAction: #selector(QuitTarget.quit(_:)))

        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(mainMenu.item(withTitle: "Kickoff")?.submenu)
        let quit = try XCTUnwrap(appMenu.item(withTitle: "Quit Kickoff"))
        XCTAssertTrue(quit.target === target)
        XCTAssertEqual(quit.action, #selector(QuitTarget.quit(_:)))
        XCTAssertEqual(quit.keyEquivalent, "q")

        let edit = try XCTUnwrap(mainMenu.item(withTitle: "Edit")?.submenu)
        assertCommand("Undo", action: "undo:", key: "z", in: edit)
        assertCommand("Redo", action: "redo:", key: "z", modifiers: [.command, .shift], in: edit)
        assertCommand("Cut", action: "cut:", key: "x", in: edit)
        assertCommand("Copy", action: "copy:", key: "c", in: edit)
        assertCommand("Paste", action: "paste:", key: "v", in: edit)
        assertCommand("Select All", action: "selectAll:", key: "a", in: edit)
    }

    private func assertCommand(
        _ title: String,
        action: String,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        in menu: NSMenu,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let item = menu.item(withTitle: title) else {
            XCTFail("Missing \(title)", file: file, line: line)
            return
        }
        XCTAssertNil(item.target, file: file, line: line)
        XCTAssertEqual(item.action, Selector((action)), file: file, line: line)
        XCTAssertEqual(item.keyEquivalent, key, file: file, line: line)
        XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, file: file, line: line)
    }
}
