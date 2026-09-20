#include "AXNavigation.h"

// Public AX keyboard API, deprecated in macOS 10.9 and unavailable directly
// to Swift. System-wide posting delivers to the foreground application.
AXError HuluAXReturnToFrontmost(void) {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXError down = AXUIElementPostKeyboardEvent(system, 0, 0x24, true);
    AXError up = AXUIElementPostKeyboardEvent(system, 0, 0x24, false);
    CFRelease(system);
    return down != kAXErrorSuccess ? down : up;
}
