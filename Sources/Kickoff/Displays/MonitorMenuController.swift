import AppKit

/// Presents monitor choices; selection/persistence and display discovery have separate owners.
final class MonitorMenuController: NSObject {
    let item = NSMenuItem(title: "Monitor", action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: "Monitor")
    private let selection: MonitorSelection
    private var screenObserver: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(selection: MonitorSelection) {
        self.selection = selection
        super.init()
        submenu.autoenablesItems = false
        item.submenu = submenu
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onChange?() }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func refresh(snapshot: MonitorSelectionSnapshot, isEnabled: Bool) {
        submenu.removeAllItems()
        item.isEnabled = isEnabled
        for monitor in snapshot.monitors {
            let choice = NSMenuItem(title: snapshot.title(for: monitor), action: #selector(choose(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = monitor.identifier
            choice.state = snapshot.target?.identifier == monitor.identifier ? .on : .off
            choice.isEnabled = isEnabled
            submenu.addItem(choice)
        }
        if snapshot.monitors.isEmpty {
            addNotice("No available monitors")
        }
        if let unavailable = snapshot.unavailablePreference {
            submenu.addItem(.separator())
            addNotice("\(unavailable.name) (Unavailable)")
        }
    }

    private func addNotice(_ title: String) {
        let notice = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        notice.isEnabled = false
        submenu.addItem(notice)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard item.isEnabled, let identifier = sender.representedObject as? String else { return }
        selection.select(identifier: identifier)
        onChange?()
    }
}
