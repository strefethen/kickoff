import CoreGraphics
import Foundation

enum ChromeSetupMode: Equatable {
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
    func setupSplitWindow(frame: CGRect) throws
    func measuredBrowserInsets() throws -> ChromeBrowserInsets
    func placeWindow(frame: CGRect) throws
    func raiseWindow() throws
    func verifySplitWindow(frame: CGRect) throws
}

extension ChromeLayout: ChromeWindowSettingUp {}

/// Coordinates complete Chrome layouts while each session owns one new window.
final class ChromeSetup {
    typealias SessionFactory = (MonitorTarget, WebsiteURL) throws -> ChromeWindowSettingUp

    private let target: MonitorTarget
    private let website: WebsiteURL
    private let makeSession: SessionFactory

    init(
        target: MonitorTarget,
        website: WebsiteURL,
        makeSession: @escaping SessionFactory = { target, website in
            try ChromeLayout(target: target, website: website)
        }
    ) {
        self.target = target
        self.website = website
        self.makeSession = makeSession
    }

    func setup(mode: ChromeSetupMode) throws {
        switch mode {
        case .split:
            try makeSession(target, website).setup()
        case .quad:
            try setupQuad()
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

    private func setupQuad() throws {
        _ = try target.validate()
        let visibleBounds = target.monitor.visibleBounds

        let top = try makeSession(target, website)
        try top.setupSplitWindow(frame: visibleBounds)

        let bottom = try makeSession(target, website)
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
