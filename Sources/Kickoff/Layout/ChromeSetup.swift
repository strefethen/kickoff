import AppKit
import CoreGraphics
import Foundation

enum ChromeSetupMode: Equatable {
    case single
    case split
    case quad
}

struct ChromeBrowserInsets: Equatable {
    let top: CGFloat
    let bottom: CGFloat

    func matches(_ other: ChromeBrowserInsets) -> Bool {
        abs(top - other.top) <= 1 && abs(bottom - other.bottom) <= 1
    }
}

protocol ChromeWindowSettingUp: AnyObject {
    func setup() throws
    func setupSingleWindow() throws
    func setupSplitWindow(frame: CGRect) throws
    func measuredBrowserInsets() throws -> ChromeBrowserInsets
    func placeWindow(frame: CGRect) throws
    func raiseWindow() throws
    func verifySplitWindow(frame: CGRect) throws
    func closeOwnedWindow() throws -> Bool
}

extension ChromeLayout: ChromeWindowSettingUp {}

struct ChromeSetupFailure: Error, CustomStringConvertible {
    let cause: Error
    let closedWindows: Int
    let cleanupFailures: [String]
    let logLocation: String
    let logFailure: String?

    var description: String {
        var parts = [String(describing: cause)]
        let openedWindows = closedWindows + cleanupFailures.count
        if cleanupFailures.isEmpty {
            if closedWindows == 1 {
                parts.append("Kickoff closed the Chrome window this setup opened.")
            } else if closedWindows > 1 {
                parts.append("Kickoff closed the \(closedWindows) Chrome windows this setup opened.")
            }
        } else {
            parts.append("Kickoff closed \(closedWindows) of the \(openedWindows) Chrome windows this setup opened. \(cleanupFailures.joined(separator: " "))")
        }
        if let logFailure {
            parts.append("The setup log at \(logLocation) stopped recording: \(logFailure)")
        } else {
            parts.append("Details: \(logLocation)")
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Coordinates complete Chrome layouts while each session owns one new window.
final class ChromeSetup {
    typealias SessionFactory = (MonitorTarget, WebsiteURL, SetupLogging) throws -> ChromeWindowSettingUp

    private let target: MonitorTarget
    private let website: WebsiteURL
    private let openLog: () throws -> SetupLogging
    private let makeSession: SessionFactory

    init(
        target: MonitorTarget,
        website: WebsiteURL,
        openLog: @escaping () throws -> SetupLogging = { try SetupLog() },
        makeSession: @escaping SessionFactory = { target, website, log in
            try ChromeApplication.ensureRunning()
            return try ChromeLayout(target: target, website: website, setupLog: log, scripting: ChromeAppleScriptClient())
        }
    ) {
        self.target = target
        self.website = website
        self.openLog = openLog
        self.makeSession = makeSession
    }

    func setup(mode: ChromeSetupMode) throws {
        let log = try openLog()
        log.record("setup-start mode=\(mode) display=\(target.monitor.name) bounds=\(NSStringFromRect(target.monitor.bounds)) visible=\(NSStringFromRect(target.monitor.visibleBounds))")
        var sessions: [ChromeWindowSettingUp] = []
        let session = { () throws -> ChromeWindowSettingUp in
            let created = try self.makeSession(self.target, self.website, log)
            sessions.append(created)
            return created
        }
        do {
            switch mode {
            case .single:
                try session().setupSingleWindow()
            case .split:
                try session().setup()
            case .quad:
                try setupQuad(session: session)
            }
            log.record("setup-complete mode=\(mode)")
        } catch {
            log.record("setup-failed mode=\(mode) error=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
            var closedWindows = 0
            var cleanupFailures: [String] = []
            for created in sessions.reversed() {
                do {
                    if try created.closeOwnedWindow() { closedWindows += 1 }
                } catch {
                    cleanupFailures.append(String(describing: error))
                }
            }
            log.record("setup-cleanup closed=\(closedWindows) failures=\(cleanupFailures.count)")
            throw ChromeSetupFailure(
                cause: error,
                closedWindows: closedWindows,
                cleanupFailures: cleanupFailures,
                logLocation: log.location,
                logFailure: log.writeFailure
            )
        }
    }

    static func quadFrames(
        in visibleBounds: CGRect,
        topInsets: ChromeBrowserInsets,
        bottomInsets: ChromeBrowserInsets
    ) throws -> (top: CGRect, bottom: CGRect) {
        let values = [
            visibleBounds.minX, visibleBounds.minY, visibleBounds.width, visibleBounds.height,
            topInsets.top, topInsets.bottom, bottomInsets.top, bottomInsets.bottom,
        ]
        guard values.allSatisfy(\.isFinite),
              visibleBounds.width > 0, visibleBounds.height > 0,
              topInsets.top >= 0, topInsets.bottom >= 0,
              bottomInsets.top >= 0, bottomInsets.bottom >= 0 else {
            throw AccessibilityFailure("Chrome exposed invalid geometry for quad view.")
        }
        let availableViewport = visibleBounds.height - topInsets.top - topInsets.bottom - bottomInsets.bottom
        let topViewport = floor(availableViewport / 2)
        let bottomViewport = availableViewport - topViewport
        guard topViewport > 0, bottomViewport > 0 else {
            throw AccessibilityFailure("The selected monitor cannot fit two Chrome website viewports.")
        }
        let top = CGRect(
            x: visibleBounds.minX,
            y: visibleBounds.minY,
            width: visibleBounds.width,
            height: topInsets.top + topViewport + topInsets.bottom
        )
        let bottomHeight = bottomInsets.top + bottomViewport + bottomInsets.bottom
        let bottom = CGRect(
            x: visibleBounds.minX,
            y: visibleBounds.maxY - bottomHeight,
            width: visibleBounds.width,
            height: bottomHeight
        )
        guard visibleBounds.contains(top), visibleBounds.contains(bottom),
              abs(top.maxY - (bottom.minY + bottomInsets.top)) <= 1 else {
            throw AccessibilityFailure("The selected monitor cannot contain the measured Chrome quad view.")
        }
        return (top, bottom)
    }

    private func setupQuad(session: () throws -> ChromeWindowSettingUp) throws {
        _ = try target.validate()
        let visibleBounds = target.monitor.visibleBounds

        let top = try session()
        try top.setupSplitWindow(frame: visibleBounds)

        let bottom = try session()
        try bottom.setupSplitWindow(frame: visibleBounds)

        let topInsets = try top.measuredBrowserInsets()
        let bottomInsets = try bottom.measuredBrowserInsets()
        let frames = try Self.quadFrames(
            in: visibleBounds,
            topInsets: topInsets,
            bottomInsets: bottomInsets
        )

        try top.placeWindow(frame: frames.top)
        try bottom.placeWindow(frame: frames.bottom)

        try top.verifySplitWindow(frame: frames.top)
        try bottom.verifySplitWindow(frame: frames.bottom)
        guard try top.measuredBrowserInsets().matches(topInsets),
              try bottom.measuredBrowserInsets().matches(bottomInsets) else {
            throw AccessibilityFailure("Chrome's browser viewport insets changed while arranging quad view.")
        }
        try top.raiseWindow()
    }
}

/// Starts an installed Chrome only when setup needs a new browser window.
enum ChromeApplication {
    static func ensureRunning(
        runningCount: () -> Int = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").count
        },
        installedURL: () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        },
        open: (URL, @escaping (Result<Void, Error>) -> Void) -> Void = { url, completion in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                if let error {
                    completion(.failure(error))
                } else if app != nil {
                    completion(.success(()))
                } else {
                    completion(.failure(AccessibilityFailure("macOS did not start Google Chrome.")))
                }
            }
        }
    ) throws {
        let count = runningCount()
        guard count <= 1 else {
            throw AccessibilityFailure("Expected one running Google Chrome process; found \(count).")
        }
        if count == 1 { return }
        guard let url = installedURL() else {
            throw AccessibilityFailure("Google Chrome is not installed.")
        }

        let completed = DispatchSemaphore(value: 0)
        var launchResult: Result<Void, Error>?
        open(url) { result in
            launchResult = result
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            throw AccessibilityFailure("Google Chrome did not start within 5 seconds.")
        }
        guard let launchResult else {
            throw AccessibilityFailure("macOS did not report whether Google Chrome started.")
        }
        do {
            try launchResult.get()
        } catch {
            throw AccessibilityFailure("Could not open Google Chrome: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(2)
        repeat {
            let count = runningCount()
            if count == 1 { return }
            if count > 1 {
                throw AccessibilityFailure("Expected one running Google Chrome process; found \(count).")
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw AccessibilityFailure("Google Chrome started but did not appear as one running process.")
    }
}
