import AppKit

/// Owns native setup-menu presentation and action guards; persistence and automation keep their existing owners.
final class SetupMenuController: NSObject, NSMenuDelegate {
    struct RuntimeState {
        var accessibilityTrusted: Bool
        var isSettingUp = false
        var isAdMutingEnabled = false
        var canRetryAdMuting = false
        var isQuitting = false
        var status = "Ready"
    }

    struct Actions {
        var setUp: (ChromeSetupMode) -> Void
        var toggleAdMuting: () -> Void
        var retryAdMuting: () -> Void
        var editWebsite: () -> Void
        var openAccessibilitySettings: () -> Void
        var showAppInFinder: () -> Void
        var quit: () -> Void
    }

    let menu = NSMenu(title: "Kickoff")
    let layoutMenu = NSMenu(title: "Layout")
    private let selection: MonitorSelection
    private let preferences: WebsitePreferences
    private let readRuntime: () -> RuntimeState
    private let actions: Actions
    private(set) var selectedLayout: ChromeSetupMode = .split
    private(set) var status = "Ready"
    var onOpen: (() -> Void)?
    private var isTracking = false
    private var statusItem: NSMenuItem?
    private var setupItem: NSMenuItem?
    private var mutingItem: NSMenuItem?
    private var retryItem: NSMenuItem?
    private var editItem: NSMenuItem?
    private var recoveryItems: [NSMenuItem] = []
    private var displayItems: [String: NSMenuItem] = [:]
    private let modes: [(ChromeSetupMode, String, String)] = [
        (.single, "One game — Full screen", "rectangle"),
        (.split, "Two games — Split", "rectangle.split.2x1"),
        (.quad, "Four games — Quad", "rectangle.split.2x2"),
    ]

    init(selection: MonitorSelection, preferences: WebsitePreferences,
         readRuntime: @escaping () -> RuntimeState, actions: Actions) {
        self.selection = selection
        self.preferences = preferences
        self.readRuntime = readRuntime
        self.actions = actions
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        layoutMenu.autoenablesItems = false
        layoutMenu.presentationStyle = .palette
        layoutMenu.selectionMode = .selectOne
        for (index, choice) in modes.enumerated() {
            let item = command(choice.1, action: #selector(chooseLayout(_:)))
            item.tag = index
            item.image = NSImage(systemSymbolName: choice.2, accessibilityDescription: choice.1)
            item.image?.isTemplate = true
            item.toolTip = choice.1
            item.setAccessibilityLabel(choice.1)
            layoutMenu.addItem(item)
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onOpen?()
        refresh()
        isTracking = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func menuDidClose(_ menu: NSMenu) {
        isTracking = false
        refresh()
    }

    func refresh() {
        let runtime = readRuntime()
        let snapshot = selection.snapshot()
        let website: String
        let websiteError: String?
        do {
            website = try preferences.currentURL().absoluteString
            websiteError = nil
        } catch {
            website = preferences.makeDraft().text
            websiteError = String(describing: error)
        }
        let canSelect = !runtime.isSettingUp && !runtime.isQuitting
        status = runtime.accessibilityTrusted ? runtime.status : "Accessibility permission needed"
        // Monitoring updates continue while the menu tracks. Keep its items and
        // selection group stable so AppKit retains keyboard highlight and focus.
        if isTracking {
            updateTrackedItems(runtime: runtime, snapshot: snapshot, websiteError: websiteError)
            return
        }
        menu.removeAllItems()
        displayItems.removeAll()
        recoveryItems.removeAll()
        retryItem = nil
        statusItem = addNotice(Self.abbreviated(status), help: status)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Display"))
        for monitor in snapshot.monitors {
            let title = snapshot.title(for: monitor)
            let item = command(Self.abbreviated(title), action: #selector(chooseDisplay(_:)))
            item.representedObject = monitor.identifier
            item.state = snapshot.target?.identifier == monitor.identifier ? .on : .off
            item.isEnabled = canSelect
            item.toolTip = title
            item.setAccessibilityLabel(title)
            menu.addItem(item)
            displayItems[monitor.identifier] = item
        }
        if snapshot.monitors.isEmpty { addNotice("No available displays") }
        if let unavailable = snapshot.unavailablePreference {
            addNotice(Self.abbreviated("Saved display unavailable: \(unavailable.name)"), help: unavailable.name)
            if let target = snapshot.target {
                let title = snapshot.title(for: target)
                addNotice(Self.abbreviated("Using \(title)"), help: "Setup target: \(title)")
            }
        }
        menu.addItem(.separator())
        // AppKit renders a palette submenu inline with native exclusive selection.
        menu.addItem(.sectionHeader(title: "Layout"))
        let layout = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        layout.submenu = layoutMenu
        menu.addItem(layout)
        for item in layoutMenu.items { item.isEnabled = canSelect }
        synchronizeLayoutSelection()
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Website"))
        addNotice(Self.abbreviated(website.isEmpty ? "No website configured" : website), help: website)
        if let websiteError { addNotice(Self.abbreviated(websiteError), help: websiteError) }
        let edit = command("Edit Website…", action: #selector(editWebsite), key: ",")
        edit.isEnabled = canSelect
        menu.addItem(edit)
        editItem = edit
        menu.addItem(.separator())
        let setup = command("Set Up Chrome", action: #selector(setUpChrome))
        setup.isEnabled = canSelect && runtime.accessibilityTrusted && snapshot.target != nil && websiteError == nil
        setup.toolTip = setupGuidance(runtime: runtime, snapshot: snapshot, websiteError: websiteError)
        menu.addItem(setup)
        setupItem = setup
        let muting = command("Ad Muting", action: #selector(toggleAdMuting))
        muting.state = runtime.isAdMutingEnabled ? .on : .off
        muting.isEnabled = canSelect && (runtime.isAdMutingEnabled || runtime.accessibilityTrusted)
        menu.addItem(muting)
        mutingItem = muting
        if runtime.canRetryAdMuting {
            let retry = command("Retry Ad Muting", action: #selector(retryAdMuting))
            retry.isEnabled = canSelect && runtime.accessibilityTrusted
            menu.addItem(retry)
            retryItem = retry
        }
        if !runtime.accessibilityTrusted {
            menu.addItem(.separator())
            let permission = command("Open Accessibility Settings…", action: #selector(openAccessibilitySettings))
            permission.isEnabled = canSelect
            menu.addItem(permission)
            let finder = command("Show App in Finder", action: #selector(showAppInFinder))
            finder.isEnabled = canSelect
            menu.addItem(finder)
            recoveryItems = [permission, finder]
            addNotice("Use + to add Kickoff, then enable it")
        }
        menu.addItem(.separator())
        menu.addItem(command("Quit Kickoff", action: #selector(quit), key: "q"))
    }

    private func updateTrackedItems(runtime: RuntimeState, snapshot: MonitorSelectionSnapshot, websiteError: String?) {
        let canSelect = !runtime.isSettingUp && !runtime.isQuitting
        statusItem?.title = Self.abbreviated(status)
        statusItem?.toolTip = status
        statusItem?.setAccessibilityLabel(status)
        for (identifier, item) in displayItems {
            item.state = snapshot.target?.identifier == identifier ? .on : .off
            item.isEnabled = canSelect && snapshot.monitors.contains { $0.identifier == identifier }
        }
        for item in layoutMenu.items { item.isEnabled = canSelect }
        synchronizeLayoutSelection()
        setupItem?.isEnabled = canSelect && runtime.accessibilityTrusted && snapshot.target != nil && websiteError == nil
        setupItem?.toolTip = setupGuidance(runtime: runtime, snapshot: snapshot, websiteError: websiteError)
        mutingItem?.state = runtime.isAdMutingEnabled ? .on : .off
        mutingItem?.isEnabled = canSelect && (runtime.isAdMutingEnabled || runtime.accessibilityTrusted)
        retryItem?.isEnabled = canSelect && runtime.accessibilityTrusted && runtime.canRetryAdMuting
        editItem?.isEnabled = canSelect
        for item in recoveryItems { item.isEnabled = canSelect }
    }

    private func synchronizeLayoutSelection() {
        let selected = layoutMenu.items.filter { modes[$0.tag].0 == selectedLayout }
        if layoutMenu.selectedItems != selected { layoutMenu.selectedItems = selected }
    }

    static func abbreviated(_ value: String, limit: Int = 48) -> String {
        guard value.count > limit else { return value }
        let head = (limit - 1) * 2 / 3
        return String(value.prefix(head)) + "…" + String(value.suffix(limit - head - 1))
    }

    private func command(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @discardableResult
    private func addNotice(_ title: String, help: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = help
        item.setAccessibilityLabel(help ?? title)
        menu.addItem(item)
        return item
    }

    private func setupGuidance(runtime: RuntimeState, snapshot: MonitorSelectionSnapshot, websiteError: String?) -> String? {
        if runtime.isSettingUp { return "Wait for Chrome setup to finish." }
        if !runtime.accessibilityTrusted { return "Allow Kickoff in Accessibility settings to set up Chrome." }
        if snapshot.target == nil { return "Connect a display to set up Chrome." }
        if let websiteError { return "Edit the website. \(websiteError)" }
        return nil
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        let runtime = readRuntime()
        guard !runtime.isSettingUp, !runtime.isQuitting, let identifier = sender.representedObject as? String else { refresh(); return }
        _ = selection.select(identifier: identifier)
        refresh()
    }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        let runtime = readRuntime()
        guard !runtime.isSettingUp, !runtime.isQuitting, modes.indices.contains(sender.tag) else { refresh(); return }
        selectedLayout = modes[sender.tag].0
        refresh()
        // A native palette permits deselecting its selected item and updates
        // state after action dispatch. Layout always retains one session choice.
        DispatchQueue.main.async { [weak self] in self?.synchronizeLayoutSelection() }
    }

    @objc private func setUpChrome() {
        let runtime = readRuntime()
        guard !runtime.isSettingUp, !runtime.isQuitting, runtime.accessibilityTrusted,
              selection.snapshot().target != nil, (try? preferences.currentURL()) != nil else { refresh(); return }
        actions.setUp(selectedLayout)
        refresh()
    }

    @objc private func toggleAdMuting() {
        let runtime = readRuntime()
        guard !runtime.isSettingUp, !runtime.isQuitting,
              runtime.isAdMutingEnabled || runtime.accessibilityTrusted else { refresh(); return }
        actions.toggleAdMuting()
        refresh()
    }

    @objc private func retryAdMuting() {
        let runtime = readRuntime()
        guard !runtime.isSettingUp, !runtime.isQuitting, runtime.accessibilityTrusted,
              runtime.canRetryAdMuting else { refresh(); return }
        actions.retryAdMuting()
        refresh()
    }

    @objc private func editWebsite() { if canRecover { actions.editWebsite() } }
    @objc private func openAccessibilitySettings() { if canRecover { actions.openAccessibilitySettings() } }
    @objc private func showAppInFinder() { if canRecover { actions.showAppInFinder() } }
    @objc private func quit() { actions.quit() }
    private var canRecover: Bool {
        let runtime = readRuntime()
        return !runtime.isSettingUp && !runtime.isQuitting
    }
}
