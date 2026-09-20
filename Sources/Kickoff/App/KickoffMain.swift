import AppKit
import Foundation

@main
struct KickoffMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            runMenuBarApp()
            return
        }
        do {
            try runCommand(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func runMenuBarApp() {
        let app = NSApplication.shared
        let delegate = MenuBarController()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func runCommand(_ arguments: [String]) throws {
        if arguments == ["--help"] {
            print("""
            Usage: Kickoff [COMMAND]
              (no command)         Run the menu-bar app.
              --inspect            Read current player mute and scoped Ad-marker states.
              --discover           Alias for --inspect.
              --listen URL         Mute the other separate-window player, then unmute URL.
              --monitors           Read available monitors and the effective setup target.
              --website            Read the website saved for the next setup.
              --diagnose-layout    Read target-monitor and Chrome window layout.
              --prepare            Create the setup-owned Chrome window on the target monitor.
              --split              Create split view in the sole target-monitor Chrome window.
              --setup              Run the complete Chrome setup on the target monitor.
              --setup-quad         Create two stacked split-view Chrome windows on the target monitor.
              --fullscreen         Enter full screen in the sole target-monitor Chrome window.

            Inspection commands are read-only. The menu-bar app starts Ad Muting automatically
            when Accessibility is trusted.
            """)
            return
        }
        let output: [String: Any]
        switch arguments.first {
        case "--inspect" where arguments.count == 1,
             "--discover" where arguments.count == 1:
            let chrome = try ChromeAccessibilityClient()
            output = [
                "chromePID": chrome.pid,
                "accessibilityTrusted": true,
                "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                "players": try HuluPlayerClient(chrome: chrome).discoveryReport(),
            ]
        case "--listen" where arguments.count == 2:
            output = try HuluPlayerClient().listen(to: arguments[1])
        case "--monitors" where arguments.count == 1:
            _ = NSApplication.shared
            output = monitorReport(MonitorSelection().snapshot())
        case "--website" where arguments.count == 1:
            output = ["websiteURL": try WebsitePreferences().currentURL().absoluteString]
        case "--diagnose-layout" where arguments.count == 1:
            _ = NSApplication.shared
            let layout = try ChromeLayout(
                target: MonitorSelection().pinTarget(),
                website: .approvedDefault
            )
            output = try layout.environment()
        case "--setup" where arguments.count == 1,
             "--setup-quad" where arguments.count == 1:
            _ = NSApplication.shared
            let target = try MonitorSelection().pinTarget()
            let website = try WebsitePreferences().currentURL()
            let mode: ChromeSetupMode = arguments[0] == "--setup-quad" ? .quad : .split
            try ChromeSetup(target: target, website: website).setup(mode: mode)
            output = try ChromeLayout(target: target, website: website).environment()
        case "--prepare" where arguments.count == 1,
             "--split" where arguments.count == 1,
             "--fullscreen" where arguments.count == 1:
            _ = NSApplication.shared
            let layout = try ChromeLayout(
                target: MonitorSelection().pinTarget(),
                website: WebsiteURL.approvedDefault
            )
            if arguments[0] == "--prepare" { _ = try layout.prepare() }
            if arguments[0] == "--split" { try layout.split() }
            if arguments[0] == "--fullscreen" { try layout.enterFullScreen() }
            output = try layout.environment()
        default:
            throw AccessibilityFailure("Invalid arguments. Run Kickoff --help.")
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func monitorReport(_ snapshot: MonitorSelectionSnapshot) -> [String: Any] {
        [
            "effectiveTargetUUID": snapshot.target.map { $0.identifier as Any } ?? NSNull(),
            "preferredMonitorUUID": snapshot.preferred.map { $0.identifier as Any } ?? NSNull(),
            "preferredMonitorName": snapshot.preferred.map { $0.name as Any } ?? NSNull(),
            "monitors": snapshot.monitors.map { monitor in
                [
                    "uuid": monitor.identifier,
                    "displayID": monitor.displayID,
                    "name": snapshot.title(for: monitor),
                    "isPrimary": monitor.isPrimary,
                    "isEffectiveTarget": snapshot.target?.identifier == monitor.identifier,
                    "bounds": NSStringFromRect(monitor.bounds),
                    "visibleBounds": NSStringFromRect(monitor.visibleBounds),
                ] as [String: Any]
            },
        ]
    }
}
