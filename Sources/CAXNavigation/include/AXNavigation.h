#pragma once
#include <ApplicationServices/ApplicationServices.h>

// Caller must verify the intended application and field are frontmost.
AXError HuluAXReturnToFrontmost(void);
