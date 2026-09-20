import AppKit

/// Owns the standard application menu used while Kickoff's settings window is active.
final class AppMenuController {
    func install(quitTarget: AnyObject, quitAction: Selector) {
        let mainMenu = NSMenu(title: "Main")

        let appItem = NSMenuItem(title: "Kickoff", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Kickoff")
        let quitItem = NSMenuItem(title: "Quit Kickoff", action: quitAction, keyEquivalent: "q")
        quitItem.target = quitTarget
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu()
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(command("Undo", action: Selector(("undo:")), key: "z"))

        let redo = command("Redo", action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(command("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(command("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(command("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(.separator())
        menu.addItem(command("Select All", action: #selector(NSResponder.selectAll(_:)), key: "a"))
        return menu
    }

    private func command(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        item.keyEquivalentModifierMask = [.command]
        return item
    }
}
