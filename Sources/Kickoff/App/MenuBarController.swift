import AppKit
import ApplicationServices
import Foundation

/// Owns only the menu-bar shell and composes the monitor/layout lifecycles.
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var screenObserver: NSObjectProtocol?
    private let operationQueue = DispatchQueue(label: "com.stevetrefethen.kickoff.operations", qos: .userInitiated)
    private let appMenuController = AppMenuController()
    private let monitorSelection = MonitorSelection()
    private let websitePreferences = WebsitePreferences()
    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController(preferences: websitePreferences)
        controller.onSave = { [weak self] in self?.refreshMenu() }
        return controller
    }()
    private lazy var setupMenuController = SetupMenuController(
        selection: monitorSelection,
        preferences: websitePreferences,
        readRuntime: { [weak self] in
            guard let self else { return .init(accessibilityTrusted: false, isQuitting: true) }
            return .init(accessibilityTrusted: AXIsProcessTrusted(),
                         isSettingUp: self.operationController.isSettingUp,
                         isMonitoring: self.operationController.isMonitoring,
                         isQuitting: self.operationController.isQuitting,
                         status: self.operationController.status)
        },
        actions: .init(
            setUp: { [weak self] mode in self?.operationController.startSetup(mode: mode) },
            toggleAdMuting: { [weak self] in self?.toggleAdMuting() },
            editWebsite: { [weak self] in self?.settingsWindowController.show() },
            openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
            showAppInFinder: { [weak self] in self?.showAppInFinder() },
            quit: { [weak self] in self?.quitApp() }
        )
    )
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

        setupMenuController.onOpen = { [weak self] in
            self?.operationController.startDefaultMonitoringIfNeeded(accessibilityTrusted: AXIsProcessTrusted())
        }
        statusItem.menu = setupMenuController.menu
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshMenu() }
        operationController.startDefaultMonitoringIfNeeded(accessibilityTrusted: AXIsProcessTrusted())
        refreshMenu()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func refreshMenu() {
        setupMenuController.refresh()
        statusItem?.button?.toolTip = setupMenuController.status
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
