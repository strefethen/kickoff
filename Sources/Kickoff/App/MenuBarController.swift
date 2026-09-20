import AppKit
import ApplicationServices
import Foundation

/// Owns only the menu-bar shell and composes the monitor/layout lifecycles.
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let adMutingMenuItem = NSMenuItem(title: "Ad Muting", action: nil, keyEquivalent: "")
    private let setupMenuItem = NSMenuItem(title: "Set Up Split Screen", action: nil, keyEquivalent: "")
    private let quadSetupMenuItem = NSMenuItem(title: "Set Up Quad Screen", action: nil, keyEquivalent: "")
    private let settingsMenuItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
    private let permissionMenuItem = NSMenuItem(title: "Open Accessibility Settings…", action: nil, keyEquivalent: "")
    private let revealMenuItem = NSMenuItem(title: "Show App in Finder", action: nil, keyEquivalent: "")
    private let permissionHint = NSMenuItem(title: "Use + to add Kickoff, then enable it", action: nil, keyEquivalent: "")
    private let operationQueue = DispatchQueue(label: "com.stevetrefethen.kickoff.operations", qos: .userInitiated)
    private let appMenuController = AppMenuController()
    private let monitorSelection = MonitorSelection()
    private let websitePreferences = WebsitePreferences()
    private lazy var settingsWindowController = SettingsWindowController(preferences: websitePreferences)
    private lazy var monitorMenuController: MonitorMenuController = {
        let controller = MonitorMenuController(selection: monitorSelection)
        controller.onChange = { [weak self] in self?.refreshMenu() }
        return controller
    }()
    private lazy var operationController: HuluOperationController = {
        let monitor = AdMonitor(operationQueue: operationQueue) { try HuluPlayerClient() }
        let controller = HuluOperationController(
            monitor: monitor,
            operationQueue: operationQueue,
            prepareSetup: { [monitorSelection, websitePreferences] mode in
                let target = try monitorSelection.pinTarget()
                let website = try websitePreferences.currentURL()
                let setup = ChromeSetup(target: target, website: website)
                return { try setup.setup(mode: mode) }
            }
        )
        controller.onChange = { [weak self] in
            self?.logStatus()
            self?.refreshMenu()
        }
        controller.onSetupFailure = { [weak self] message in self?.showSetupFailure(message) }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = operationController
        appMenuController.install(quitTarget: self, quitAction: #selector(quitApp))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(systemSymbolName: "american.football", accessibilityDescription: nil)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("Kickoff controls")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        configure(adMutingMenuItem, action: #selector(toggleAdMuting))
        menu.addItem(adMutingMenuItem)
        menu.addItem(.separator())

        menu.addItem(monitorMenuController.item)
        configure(setupMenuItem, action: #selector(setUpChrome))
        configure(quadSetupMenuItem, action: #selector(setUpQuadView))
        configure(permissionMenuItem, action: #selector(openAccessibilitySettings))
        configure(revealMenuItem, action: #selector(showAppInFinder))
        menu.addItem(setupMenuItem)
        menu.addItem(quadSetupMenuItem)
        menu.addItem(permissionMenuItem)
        menu.addItem(revealMenuItem)
        permissionHint.isEnabled = false
        menu.addItem(permissionHint)
        menu.addItem(.separator())

        configure(settingsMenuItem, action: #selector(showSettings))
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kickoff", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        operationController.startDefaultMonitoringIfNeeded(accessibilityTrusted: AXIsProcessTrusted())
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        operationController.startDefaultMonitoringIfNeeded(accessibilityTrusted: AXIsProcessTrusted())
        refreshMenu()
    }

    private func configure(_ item: NSMenuItem, action: Selector) {
        item.target = self
        item.action = action
    }

    private func refreshMenu() {
        let trusted = AXIsProcessTrusted()
        let monitorSnapshot = monitorSelection.snapshot()
        let targetTitle = monitorSnapshot.target.map { monitorSnapshot.title(for: $0) }
        statusMenuItem.title = trusted ? operationController.status : "Accessibility permission needed"
        adMutingMenuItem.state = operationController.isMonitoring ? .on : .off
        adMutingMenuItem.isEnabled = !operationController.isSettingUp &&
            (operationController.isMonitoring || trusted)
        setupMenuItem.title = targetTitle.map { "Set Up Split Screen on \($0)" } ?? "Set Up Split Screen"
        setupMenuItem.isEnabled = trusted && !operationController.isSettingUp && targetTitle != nil
        quadSetupMenuItem.title = targetTitle.map { "Set Up Quad Screen on \($0)" } ?? "Set Up Quad Screen"
        quadSetupMenuItem.isEnabled = trusted && !operationController.isSettingUp && targetTitle != nil
        monitorMenuController.refresh(
            snapshot: monitorSnapshot,
            isEnabled: !operationController.isSettingUp
        )
        permissionMenuItem.isEnabled = !operationController.isSettingUp
        revealMenuItem.isEnabled = !operationController.isSettingUp
        permissionHint.isHidden = trusted
        statusItem.button?.toolTip = statusMenuItem.title
    }

    private func logStatus() {
        let event: [String: Any] = [
            "event": "status",
            "monitoring": operationController.isMonitoring,
            "settingUp": operationController.isSettingUp,
            "message": operationController.status,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    @objc private func toggleAdMuting() {
        operationController.toggleMonitoring(accessibilityTrusted: AXIsProcessTrusted())
    }

    @objc private func setUpChrome() {
        guard AXIsProcessTrusted() else { refreshMenu(); return }
        operationController.startSetup(mode: .split)
    }

    @objc private func setUpQuadView() {
        guard AXIsProcessTrusted() else { refreshMenu(); return }
        operationController.startSetup(mode: .quad)
    }

    @objc private func openAccessibilitySettings() {
        guard !operationController.isSettingUp else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Accessibility settings could not open"
            alert.informativeText = "Open System Settings → Privacy & Security → Accessibility. Use + to add Kickoff, then enable it. Show App in Finder locates this running copy."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        refreshMenu()
    }

    @objc private func showAppInFinder() {
        guard !operationController.isSettingUp else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func showSettings() {
        settingsWindowController.show()
    }

    @objc private func quitApp() {
        operationController.stopForQuit { NSApp.terminate(nil) }
    }

    private func showSetupFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Chrome setup could not finish"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
