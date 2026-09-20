import AppKit
import CoreGraphics

/// Reads connected, awake, drawable desktops. AirPlay discovery/connection is not involved.
enum SystemMonitorProvider {
    static func monitors() -> [Monitor] {
        if !Thread.isMainThread { return DispatchQueue.main.sync { monitors() } }
        let primary = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0,
                  CGDisplayIsAsleep(id) == 0, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let visible = screen.visibleFrame
            // AX/Quartz uses top-left origins; AppKit visibleFrame uses bottom-left origins.
            let visibleBounds = CGRect(
                x: bounds.minX + visible.minX - screen.frame.minX,
                y: bounds.minY + screen.frame.maxY - visible.maxY,
                width: visible.width,
                height: visible.height
            )
            return Monitor(
                identifier: CFUUIDCreateString(nil, uuid) as String,
                displayID: id, name: screen.localizedName, isPrimary: id == primary,
                bounds: bounds, visibleBounds: visibleBounds
            )
        }
    }
}
