#include "AXNavigation.h"

// Public AX keyboard API, deprecated in macOS 10.9 and unavailable directly
// to Swift. System-wide posting delivers to the foreground application.
static AXError KickoffAXKeyToFrontmost(CGKeyCode keyCode) {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXError down = AXUIElementPostKeyboardEvent(system, 0, keyCode, true);
    AXError up = AXUIElementPostKeyboardEvent(system, 0, keyCode, false);
    CFRelease(system);
    return down != kAXErrorSuccess ? down : up;
}

AXError HuluAXReturnToFrontmost(void) {
    return KickoffAXKeyToFrontmost(0x24);
}

AXError KickoffAXBackspaceToFrontmost(void) {
    return KickoffAXKeyToFrontmost(0x33);
}
